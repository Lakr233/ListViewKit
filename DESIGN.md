# ListViewKit 3.0 设计

本文是 3.0 的施工图。2.x 的问题、3.0 的模型、要砍掉的 API、以及分几步落地，
都在这里。每一步单独 commit，每一步都要有测试和 benchmark 数字。

---

## 0. 为什么要动

`Benchmarks/` 拆分之后测出来的基线（Release，800×600 视口，44pt 固定行高）：

| Items  | Initial layout | 20k visible queries | 20k offset writes | 1k scroll layouts | 200 snapshot appends | 20 width reflows |
| -----: | -------------: | ------------------: | ----------------: | ----------------: | -------------------: | ---------------: |
|   1000 |         3.5 ms |             10.5 ms |            498 ms |             50 ms |               399 ms |            26 ms |
|  10000 |        31.6 ms |             11.5 ms |            507 ms |             79 ms |             3 675 ms |           243 ms |
| 100000 |         362 ms |             12.3 ms |            503 ms |             93 ms |            44 928 ms |          3 050 ms |

换算成单次操作，三个数字不能接受：

```
  往 10 万行的列表追加一条消息      225 ms      ← 一次 UI 卡死
  10 万行首次布局                   362 ms      ← 打开就卡
  10 万行宽度变化一次               152 ms      ← 拖窗口每帧都卡
  每次 contentOffset 写             25 µs       ← 纯浪费，是可见区间查询的 50 倍
```

`sample` 的归因（append 负载，841 个主线程样本）：

```
  478 (57%)  applySnapshot → prepareVisibleRows → indices() → LayoutCache.rebuild()
               ├ 175  rebuildFrame()            每行一次 Dictionary 写
               ├  93  Set<AnyHashable>.insert   每行一次装箱
               ├  60  heightCache[key]          每行一次 AnyHashable 哈希
               ├  43  heightCache.keys.filter   全量扫陈旧 key
               └  37  identifier(for:)          每行一次 weak load + 存在类型调用
  363 (43%)  difference(with:)
               └ 3 个 Set + 2 个 Dictionary + 1 个 OrderedDictionary，全是 O(n) 分配

  叶子节点：AnyHashable.init → swift_dynamicCast → _conformsToProtocol
            → dyld4::APIs::_dyld_find_protocol_conformance
            每一行都在做一次动态协议一致性查找。
```

根因只有一句话：**diff 已经算出了谁增谁删谁动，却没人用，最后还是全量重建。**
触发点是 `ListView+LayoutCache.swift:29` 那个启发式：

```swift
var isCacheInvalid: Bool { numberOfItems != heightCache.count }
```

数量对不上就全量 rebuild。追加一行 → 数量对不上 → 走一遍 10 万行。

---

## 1. 分层

```
┌────────────────────────────────────────────────────────────────────────┐
│  应用层                                                                  │
│     list.register(...)    list.apply([Item])    list.update(item)       │
└──────────────────────────────────┬─────────────────────────────────────┘
                                   │   只有这一个门面，一个对象
┌──────────────────────────────────▼─────────────────────────────────────┐
│  ListView<Item>                                    (final, UIKit/AppKit)│
│    · 复用池、可见行装配、frame 下发                                        │
│    · 只做一件跟布局有关的事：把「要测哪些行」问给 engine，                    │
│      再把「测出来是多少」答回去                                            │
└────────┬───────────────────────────────────────────────┬───────────────┘
         │                                                │
┌────────▼─────────────────────────────┐  ┌───────────────▼──────────────┐
│  ListLayoutEngine                    │  │  ListScrollView              │
│  纯模型 — 不 import UIKit/AppKit       │  │  UIKit : UIScrollView 薄封装  │
│  不知道 view、adapter、dataSource 存在  │  │  AppKit: 自绘滚动 + 物理曲线   │
│                                       │  │          + overlay scroller  │
│  · Fenwick(height)  前缀和            │  │                              │
│  · Fenwick(pending) 未测计数           │  └──────────────────────────────┘
│  · 切片调度 + 滚动补偿量计算            │
└───────────────────────────────────────┘
```

`ListLayoutEngine` 不 import 任何 UI 框架，是这次重构的核心收益：它可以在几微秒
内跑几十万次单元测试，不需要 view、不需要主线程、不需要 run loop。

---

## 2. 核心模型：切片式延迟布局

2.x 里 `deferredSizeCalculation` 是个默认关闭的开关。3.0 里它是**唯一的布局模型**，
开关消失。

### 2.1 数据结构

```
ListLayoutEngine
──────────────────────────────────────────────────────────────────────────
  slot        0      1      2      3      4      5      6     ...   n-1
            ┌──────┬──────┬──────┬──────┬──────┬──────┬──────┬───┬──────┐
  height    │ 44 e │ 44 e │  92  │ 118  │  76  │ 44 e │ 44 e │...│ 44 e │
            └──────┴──────┴──────┴──────┴──────┴──────┴──────┴───┴──────┘
  pending   │  1   │  1   │  0   │  0   │  0   │  1   │  1   │...│  1   │
                            └──── 视口内，本帧同步测过 ────┘

  e = estimated。出生时从「已测行的均值」取一个数，之后**永不回改**。
      回改会让所有未测行的前缀和一起漂移，滚动条就会抖。

  ┌─ Fenwick A：高度前缀和 ──────────────┐  ┌─ Fenwick B：未测计数 ────────┐
  │   offsetOf(i)  = Σ[0,i)    O(log n) │  │  pendingIn(range)  O(log n) │
  │   totalHeight  = Σ[0,n)    O(1)     │  │  nearestPending(i) O(log n) │
  │   indexAt(y)   = 下界搜索   O(log n) │  │  setPending(i,_)   O(log n) │
  │   setHeight(i) = 单点更新   O(log n) │  │                             │
  └─────────────────────────────────────┘  └─────────────────────────────┘

  没有 Dictionary。没有 AnyHashable。没有 weak load。没有存在类型。
  热路径上全部是 [CGFloat] / [Int32] 上的整型加法，内存连续。
```

Fenwick B 是干掉 2.x 那个 O(n²log n) drain 的关键。现在的
`nextEstimatedIndices(near:limit:)` 每次都要遍历整个 `estimatedIdentifiers` 再
`sort()`，还是在 `limit: 1` 的循环里调的。换成「未测计数」的树之后，
「离视口最近的未测行是哪个」是一次 O(log n) 的下降搜索。

### 2.2 一帧里发生什么

```
                          ┌────────── viewport ──────────┐
   ... ──┬────┬────┬────┬─┼──┬────┬────┬────┬────┬────┬──┼─┬────┬────┬── ...
         │ P3 │ P2 │ P1 │ │S │ S  │ S  │ S  │ S  │ S  │  │ │ P1 │ P2 │
   ... ──┴────┴────┴────┴─┼──┴────┴────┴────┴────┴────┴──┼─┴────┴────┴── ...
                          └──────────────────────────────┘

   S       同步测量。这一帧就要上屏，没有第二种选择。
           数量 ≈ 视口能装下的行数，与 n 无关。
   P1..Pk  切片。nearestPending 每次 O(log n) 取一个，由近及远，
           一帧内一直取到时间预算用完为止。
```

```
   一帧 (120 Hz → 8.3 ms)
   ├──────────┬──────────┬──────────────┬───────────────┬────────────────┤
   │  event   │  scroll  │  可见行装配   │  slice ≤ 2ms  │     render     │
   └──────────┴──────────┴──────────────┴───────┬───────┴────────────────┘
                                                │
                     超预算 ──────────────────▶ 立刻停，剩下的下一帧继续
                     用户正在拖 / 宽度还在变 ──▶ 整片跳过（测了也白测）
                     pending 归零 ────────────▶ 不再调度，零开销
```

### 2.3 滚动补偿：锚点必须纹丝不动

切片修正了视口**上方**的一行，会把下面所有东西往下推。必须同量反向补偿。

```
   切片把 row 5 从估算 44 修正为实测 118  (Δ = +74)

          before                                after
       ┌────────────┐ y=0                   ┌────────────┐ y=0
       │   row 5    │ 44  (est)             │            │
       ├────────────┤                       │   row 5    │ 118 (measured)
       │   row 6    │ 44  (est)             │            │
   ════╪════════════╪═══ 视口顶 ══════════════╪════════════╪════  ← 必须不动
       │   row 7    │                       │   row 6    │
       │   row 8    │                       │   row 7    │
       └────────────┘                       └────────────┘

   engine.applyMeasurements(...) 返回 Δ = +74
        │
        └─▶ compensateScrollOffset(by: +74)
              contentOffset.y += 74      → 屏幕上一个像素都没动
              contentSize.height += 74   → 滚动条比例平滑变化，不跳
```

补偿量的定义很关键，而且**锚点是一个行下标，不是一条 y 坐标线**。

视口顶边几乎不会正好落在行的边界上，它通常切在某一行的中间。那一行如果不补偿，它变矮
多少，下面所有内容就整体上移多少 —— 这正是"reload 之后内容跳一下"的来源：

```
   viewport 顶边切在 row 2 中间，row 2 从 100 缩到 40

        锚点 = 视口顶边 (错)                    锚点 = row 3 的顶 (对)

     ┌──────────┐                          ┌──────────┐
     │  row 2   │ 100                      │  row 2   │ 100
   ══╪══════════╪══ 视口顶 ═══════════════════╪══════════╪══ 视口顶
     │          │                          │          │
     ├──────────┤ ← row 3 在屏幕 y=50        ├──────────┤ ← row 3 在屏幕 y=50
     │  row 3   │                          │  row 3   │
                                    
     row 2 → 40，不补偿                      row 2 → 40，补偿 −60
     ┌──────────┐                          ┌──────────┐
   ══╡  row 2   ╞══ 视口顶 ══════════════════╡  row 2   │  ← 顶部往上缩出屏幕
     ├──────────┤ ← row 3 跳到屏幕 y=-10    ══╪══════════╪══ 视口顶
     │  row 3   │        ✗ 内容抖了          ├──────────┤ ← row 3 仍在 y=50  ✓
```

所以 `anchorIndex(in:)` 取**第一个起点落在视口内的行**：被顶边切开的那一行算"上方"，
它的回流由 offset 吸收。唯一的例外是某一行同时越过了底边 —— 整个视口就它一个，没有别
的东西可以钉住，此时锚点就是它自己，它的回流出现在屏幕下方。

用下标而不用 y 坐标还有一个原因：一次 drain 会连续量很多行，上方内容一直在移动，一条
写死的 y 线会漂；下标不会。

`ListViewAnchorAppKitTests` 和 `ListViewSlicedLayoutAppKitTests` 里的
`backgroundMeasurementKeepsBottomPinnedListStationary`、
`backgroundMeasurementKeepsMidListAnchorStationary`、
`shrinkingAStraddlingRowKeepsTheRowsBelowStationary`、
`drainConvergesToTheFullyMeasuredResult` 钉住这件事。

**锚点钉不住的时候。** 补偿是直接写 `contentOffset` 的，不走钳位 —— 内容缩短时它本来
就要先越过边界，再由随后的 `contentSize` 落回来。所以"offset 现在在界外"不能用来判断
要不要修正，能用的判断只有**谁在控制这个 offset**：

```
   contentSize 变了
        │
        ├─ 手指 / 惯性 / 回弹 / 拖滚动条在跑  ──▶ 不管
        │     它们每帧自己钳位，插手就是把回弹掐断
        │
        ├─ 有 scrollingTarget 且它出界了     ──▶ 重新指向新边缘
        │     回弹的落点也存在这里：留着不动会停在内容外面，再没人来救
        │
        └─ 其它（闲置）                      ──▶ 直接落到新边缘，不做动画
              切片测量会反复改 contentSize，每次都做动画等于自己在滚
              例外：apply(animated:) 期间置了 animatesContentSizeCorrection，
              这时视口要跟着行一起走，否则动画中间视口硬切
```

### 2.4 结构变更走 splice，不再全量 rebuild

```
   apply([Item])
        │
        ▼
   ┌──────────────────────────────────────────────────────┐
   │  diff — 单趟 Heckel，输出全是 Int index                 │
   │     removed[]   inserted[]   moved[]   updated[]      │
   │     零中间 Set / Dictionary                            │
   └──────────────────────────┬───────────────────────────┘
                              ▼
   ┌──────────────────────────────────────────────────────┐
   │  engine.transact { ... }                              │
   │     remove(at:count:)     O(k log n)                  │
   │     insert(at:count:)     O(k log n)  → pending = 1   │
   │     move(from:to:)        O(log n)    高度跟着 id 走    │
   │     invalidate(at:)       O(log n)    → pending = 1   │
   └──────────────────────────┬───────────────────────────┘
                              ▼
                       requestLayout()
                       —— 结束。不重建任何东西。
                       下一帧只测视口里那十几行。
```

对比：

```
   2.x   append 1 行到 10 万行
         diff O(n) ──▶ isCacheInvalid 猜到不一致 ──▶ rebuild() 全量
                                                    ├ 10 万次 AnyHashable 装箱
                                                    ├ 10 万次 swift_dynamicCast
                                                    ├ 10 万次 weak load
                                                    └ 10 万次 Dictionary 写
                                                    = 225 ms

   3.0   diff O(n)（还是要过一遍新数组，避不掉）
         ──▶ engine.insert(at: n, count: 1)
             = 一次 Fenwick 点更新，17 次加法
                                                    = 目标 < 1 ms
```

`identity → 已测高度` 的映射只在应用 diff 的那一瞬间用一次，用来让被 move / insert
影响到的行保住已经测过的高度。布局路径完全不碰 identifier。

---

## 3. 公开 API：9 个类型砍到 4 个

### 3.1 类型表

```
   2.x 对外类型                              3.0
   ──────────────────────────────────────────────────────────────────────
   ListView                     open     →  ListView<Item>        final
   ListScrollView               open     →  ListScrollView        open
   ListRowView                  open     →  ListRowView           open
   ListRowPosition              (嵌套)    →  ListRowPosition       顶层
   ──────────────────────────────────────────────────────────────────────
   ListViewAdapter              protocol →  ✗  并入 ListView.register
   ListViewTypedAdapter         final    →  ✗  同上
   ListViewDataSource           open     →  ✗  内部化
   ListViewDiffableDataSource   class    →  ✗  并入 ListView.apply
   ListViewDataSourceSnapshot   struct   →  ✗  用户自己的 [Item] 就是快照
   AnimationBlockView           open     →  ✗  移进 Example
   ListView.deferredSizeCalculation      →  ✗  默认且唯一的模型
   ListView.invaliateLayout()   depr.    →  ✗
```

### 3.2 调用方对比

```swift
// ─── 2.x ────────────────────────────────────────────────────────────────
final class MessageListController {
    let listView = ListView(frame: .zero)
    let dataSource: ListViewDiffableDataSource<Message>   // 必须自己持有
    let adapter: ListViewTypedAdapter<Message, Message.RowKind>  // 必须自己持有

    init() {
        adapter = ListViewTypedAdapter { _, _, _ in .text }
        dataSource = ListViewDiffableDataSource(listView: listView)
        listView.adapter = adapter
        adapter.register(
            .text,
            makeRow: TextRow.init,
            height: { listView, message, _ in
                TextRow.height(for: message.text, width: listView.bounds.width)
            },
            configure: { _, row, message, _ in row.configure(with: message.text) }
        )
    }

    func add(_ message: Message) {
        var snapshot = dataSource.snapshot()      // O(n) 拷贝
        snapshot.append(message)
        dataSource.applySnapshot(snapshot, animatingDifferences: true)  // O(n) 拷贝 + O(n) diff
    }
}

// ─── 3.0 ────────────────────────────────────────────────────────────────
final class MessageListController {
    let list = ListView<Message>()                 // 一个对象，不用管弱引用

    init() {
        list.rowKind = { message, _ in message.kind }
        list.register(TextRow.self, for: .text) { row, message, ctx in
            row.configure(with: message.text)
        } height: { message, ctx in
            TextRow.height(for: message.text, width: ctx.width)
        }
    }

    func add(_ message: Message) {
        list.apply(messages, animated: true)       // 用户自己的数组就是快照
    }

    func stream(_ message: Message) {
        list.update(message)                       // 单条，不 diff，O(log n)
    }
}
```

`ctx`（`ListRowContext`）带 `width` / `index` / 未来的 `traits`，比现在往闭包里塞
`ListView` 干净，也避免了循环引用陷阱。

### 3.3 保留的 API

```
   ListView<Item>
     apply(_:animated:)          update(_:)          remove(id:)
     register(_:for:height:configure:)               rowKind
     scrollToRow(_:at:animated:) scrollToBottom(animated:)
     visibleRows                 rowView(for:)       rectForRow(id:)
     invalidateLayout(id:)       invalidateLayout()
     topInset  bottomInset       estimatedRowHeight
     isScrolledToBottom(tolerance:)   isUserInteractingWithScroll

   ListScrollView（滚动基座，原样保留，仅收敛内部成员）
     contentOffset  contentSize  contentInsets
     minimumContentOffset  maximumContentOffset
     scroll(to:angularFrequency:preserveVelocity:)   cancelCurrentScrolling()
     hasVerticalScroller  autohidesScrollers  flashScrollers()
```

---

## 4. Auto Layout：支持，但按 row kind opt-in

「给定宽度，反推高度」是可行的 —— 这就是 `UITableView.automaticDimension` 那套。
3.0 支持它，但**不做成全局模式**，而是注册 row kind 时二选一。原因是两条路径的
单行成本差两到三个数量级，切片调度必须知道自己面对的是哪一种。

### 4.1 两种测高来源

```
   A. 闭包测高（默认，快路径）
   ─────────────────────────────────────────────────────────────────────
      list.register(TextRow.self, for: .text) { row, item, ctx in
          row.configure(item.text)
      } height: { item, ctx in
          TextRow.height(for: item.text, width: ctx.width)
      }

      · 不需要 view，纯计算
      · 典型 1–10 µs / 行
      · 2ms 的切片预算一帧能测 200–2000 行

   B. Auto Layout 自测高（opt-in）
   ─────────────────────────────────────────────────────────────────────
      list.register(CardRow.self, for: .card, estimatedHeight: 80) {
          row, item, ctx in row.configure(item)
      }
      // 没有 height 闭包 ⇒ 走 fittingSize

      · 每个 kind 一个常驻 prototype，配置一次量一次
      · 典型 50–500 µs / 行
      · 2ms 的切片预算一帧只能测 4–40 行
```

### 4.2 测量管线

```
   engine 说「第 i 行还没测，宽度 W」
        │
        ├── kind 注册了 height 闭包 ──▶ height(item, ctx)          ~µs
        │                                                    ──▶ engine.setHeight
        │
        └── kind 没有 height 闭包   ──▶ ┌─────────────────────────────────┐
                                        │  prototype(for: kind)            │
                                        │    · 每个 kind 一个，全局复用      │
                                        │    · 挂在 ListView 上但 isHidden  │
                                        │      （要继承 trait / appearance） │
                                        │    · translatesAutoresizing = false│
                                        │      —— 它是量具，不是行           │
                                        ├─────────────────────────────────┤
                                        │  widthConstraint.constant = W    │
                                        │  configure(proto, item,          │
                                        │            ctx.purpose(.measuring))│
                                        │  UIKit : systemLayoutSizeFitting  │
                                        │          (.required, .fitting)    │
                                        │  AppKit: layoutSubtreeIfNeeded()  │
                                        │          → fittingSize.height     │
                                        └─────────────┬───────────────────┘
                                                      ▼  ~50–500 µs
                                                engine.setHeight
```

`ctx.purpose` 是 `.measuring` / `.display`。量高的时候 configure 会跑在一个永远不上屏
的 prototype 上，所以：

```
   func configure(_ row: CardRow, _ item: Item, _ ctx: ListRowContext) {
       row.title.text = item.title           // 影响高度，必须做
       guard ctx.purpose == .display else { return }
       row.avatar.load(item.avatarURL)       // 不影响高度，量高时别做
   }
```

没有这个开关，一次全量 drain 会对 10 万行各发一次头像请求。

### 4.3 prototype 是量具，行是行 —— 两者规则不同

```
   ┌─ prototype（离屏，每 kind 一个）──────────────────────────────────┐
   │   translatesAutoresizingMaskIntoConstraints = false               │
   │   宽度由一根可变 width 约束钉住                                     │
   │   高度由内部约束自己撑出来 → fittingSize.height                     │
   │   永不上屏，isHidden = true，不参与命中测试                          │
   └───────────────────────────────────────────────────────────────────┘

   ┌─ 真正显示的 row ─────────────────────────────────────────────────┐
   │   translatesAutoresizingMaskIntoConstraints = true                │
   │   frame 由 ListView 直接写死（engine 算出来的）                     │
   │   内部子视图想用 Auto Layout 随便，那是 row 自己的事                 │
   │   ListView 不读它的 intrinsicContentSize，                         │
   │   不调它的 systemLayoutSizeFitting，不给它装任何约束                 │
   └───────────────────────────────────────────────────────────────────┘
```

这条边界是关键：**行的外框永远是 frame 驱动的**。Auto Layout 只在量具上跑一次，
量完就把一个 `CGFloat` 交给 engine，之后布局路径跟闭包测高完全一样。所以
profile 里那些 `_findAnySubviewNeedingAutoLayoutEngine` / `_NSAddKeyValueDependency`
的成本只发生在 prototype 上，不会随可见行数放大。

### 4.4 为什么反而是切片模型让 Auto Layout 变得可用

```
   2.x 的同步模型 + Auto Layout 自测高
       10 万行 × 200 µs = 20 秒的同步测量 ────▶ 直接 ANR，不可用

   3.0 的切片模型 + Auto Layout 自测高
       视口内 ~14 行同步     14 × 200 µs = 2.8 ms   ← 可接受
       其余 99 986 行切片     每帧 2ms 预算，约 10 行/帧
                            → 约 10 000 帧 ≈ 80 秒后台补完
       期间列表用估算高度撑着，可滚动、可交互、滚动条平滑
```

代价是诚实的：**大列表 + Auto Layout 自测高，滚动条比例会在后台补测的过程中慢慢
收敛到准确值。** 这是所有自测高列表都有的性质（`UITableView` 同样如此），换来的是
不卡。想要精确滚动条就给 height 闭包。

文档里会明确写：**行数上万时优先用 height 闭包；Auto Layout 自测高适合几百行以内、
或者行结构复杂到手算高度不现实的场景。**

---

## 5. 落地顺序

一步一个 commit，每步都要有测试和 benchmark 数字。前 5 步不动公开 API，
第 6、7 步才 breaking。

```
  #  commit                            状态      结果
 ────────────────────────────────────────────────────────────────────────────
  0  bench: 拆分 benchmark              ✅ 079cedf
     建立可归因的基线                              发现「25µs/query」其实是
                                                 contentOffset 写，不是二分查找

  1  perf: AppKit scroller 拆几何/位置    ✅ 3836d01
                                                 20k offset writes
                                                 503ms → 22ms  (23×)
                                                 1k scroll layouts 93 → 87ms
     review 抓到 3 个 P0：layoutContent 顺序、bounds.origin 跟随、
     placement memo 键错（inset 改变但 range 不变）

  2  feat: ListLayoutEngine             ✅ 684ec7d
     Fenwick 单树（高度和 + 未测计数）              10 万随机操作对拍朴素实现
                                                 review 抓到 2 个 P0：浮点降序
                                                 vs 前缀和不一致（→ 行高 ceil 成
                                                 整点）、indices() 越界返回末行

  3  perf: diff 单趟化                   ✅ 448c20c
     去掉 3 Set + 2 Dictionary                    10k appends 3753 → 2557ms
                                                 顺序从 Set 迭代变确定性

  4  refactor!: 切片布局成为唯一模型       ✅ befac74
     删掉 LayoutCache / DeferredMeasurement       100k: initial 362 → 52ms
     / deferredSizeCalculation                    width reflow 152 → 4ms/次
                                                  tail updates 33.7 → 10.6ms
                                                  visible queries 11.8 → 3.2ms
                                                  append 225 → 37ms/条
     review 抓到 2 个 P0 + 1 个 P1：固定 4 次收敛循环不够、
     替换 dataSource 未清旧状态、无 adapter 时死循环

  5  refactor: 去掉 Deque + Reference    ✅ 2987d8a
     复用池改 LIFO 普通数组                        只剩 OrderedDictionary 还依赖
                                                 swift-collections

 ────────────────────────────────────────────────────────────────────────────
  6  api!: 合并进 ListView<Item>          ✅ 6d1d9f6
     rows { } DSL，Auto Layout 按行类型             公开类型 9 → 4 个概念
     opt-in，append/update 增量 API                append 225ms → 0.03ms/条
     顺手去掉 OrderedDictionary                     swift-collections 彻底移除
     review 抓到 2 个 P0 + 1 个 P1：动画前未测量、rows{} 泄漏 prototype、
     动画 completion 强制同步布局

  7  docs: README / 迁移指南 / 3.0.0      ✅
 ────────────────────────────────────────────────────────────────────────────
  8  feat: overscan / preload range      ⬜ 待做    真机快滑不掉帧
     Texture 的 leading/trailing screenful          （benchmark 测不出，要手滑
                                                    + Instruments）
```

### 当前完成度

100k 行，Release，800×600 视口：

| 指标 | 2.x 基线 | 现在 | 倍数 |
| --- | ---: | ---: | ---: |
| Initial layout | 362 ms | 42 ms | 8.6× |
| 20k visible queries | 11.8 ms | 3.0 ms | 3.9× |
| 20k offset writes | 503 ms | 21 ms | 24× |
| 1k tail item updates | 33.7 ms | 9.7 ms | 3.5× |
| 追加一行 | 225 ms | 0.03 ms | 7500× |
| 20 width reflows | 3050 ms | 99 ms | 31× |

测试从 39 个涨到 66 个，多次连跑无 flake。

第 2 步的对拍测试是正确性的地基：拿一个「朴素实现」（就是个 `[CGFloat]` 数组，
每次线性求和），和 Fenwick 引擎跑同一串 10 万次随机 insert/remove/move/setHeight，
每一步都比对 `offsetOf` / `indexAt` / `totalHeight` / `nearestPending`。
这个测试跑得起来，后面 5 步才敢改。

---

## 6. 风险

| 风险 | 处理 |
| --- | --- |
| 泛型 `ListView<Item>` 在 AppKit 下 override 失效 | 已验证：泛型 NSView 子类的 `isFlipped` / `layout()` / `viewDidMoveToWindow()` / `hitTest` override 均正常 |
| 估算高度不准导致滚动条跳 | 估算值出生即固定、永不回改；估算基数取已测均值；`estimatedRowHeight` 可显式指定 |
| 切片在低端机吃掉帧预算 | 时间预算（默认 2ms）而非行数预算；用户交互 / 宽度变化期间整片跳过 |
| 一次性删掉 5 个公开类型，下游迁移成本 | 3.0 是 major；第 7 步单独 commit，配迁移指南；1~6 步不动 API，可先单独发 2.x patch |
