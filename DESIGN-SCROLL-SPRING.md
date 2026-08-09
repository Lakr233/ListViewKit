# 滚动阻尼：iMessage 式的弹性间隙

DESIGN.md 第 5 节路线图的第 9 步。本文是这一步的施工图。

本稿是第二版。第一版被一次对着源码的逐条复核推翻了三个地方：位移的落地方式、
挂载矩形的外扩方式、以及协议里「默认实现该做什么」。原因写在各节里，
因为那三个错误都不是笔误，是推理链上的洞，值得留着。

---

## 0. 要做的是什么

滚动时，行不再严格跟着 `contentOffset` 走，而是按「离锚点多远」滞后一点；
滞后量的差就是被拉开的间隙。手一停，滞后量弹回零，几何回到 engine 算的真值。

关键限定：**这是纯表现层的位移。** `ListLayoutEngine` 依然是唯一真值，
`rectForRow` / `scrollToRow` / `indices(intersecting:)` 报告的全是静止几何。
位移不进任何公开几何 API，不影响测量、不影响补偿、不影响 diff。

「不影响布局」这句话第一版是靠「位移走 transform，所以 `frame` 保持真值」来兑现的。
那条路是错的（§4）。终版靠的是给 `ListRowView` 加一个显式的真值字段 `placedFrame`，
把「engine 说它在哪」和「它现在画在哪」拆成两个通道。

---

## 1. 参考实现，以及为什么不能抄

公开的原型只有一份，2013 年 Ash Furrow 发在 objc.io 的
`ASHSpringyCollectionViewFlowLayout`（源自 Teehan+Lax 的 demo）。
onevcat 的 `VVSpringCollectionViewFlowLayout`、ScottLogic 的 iOS7 Day-by-Day、
72lions 的 BouncyCollectionView 都是它的变体，只改了参数。核心是这几行：

```objc
CGFloat delta = newBounds.origin.y - scrollView.bounds.origin.y;
CGPoint touchLocation = [self.collectionView.panGestureRecognizer locationInView:self.collectionView];

CGFloat yDistanceFromTouch = fabsf(touchLocation.y - springBehaviour.anchorPoint.y);
CGFloat xDistanceFromTouch = fabsf(touchLocation.x - springBehaviour.anchorPoint.x);
CGFloat scrollResistance = (yDistanceFromTouch + xDistanceFromTouch) / 1500.0f;

if (delta < 0) center.y += MAX(delta, delta*scrollResistance);
else           center.y += MIN(delta, delta*scrollResistance);
```

每行挂一个 `UIAttachmentBehavior`（`length = 0`，`damping` 0.5–0.8，
`frequency` 0.8–1.0）锚在流式布局位置上，每帧把行推离锚点，剩下的交给
`UIDynamicAnimator`。

四条硬伤，每条都单独致命：

| | |
| --- | --- |
| AppKit 没有 UIKit Dynamics | 本库 macOS 侧是手写的 `AppKitScrollPhysics`，引不进 iOS-only 的物理引擎 |
| `panGestureRecognizer` 触控板上不存在 | objc.io 自己承认 `touchLocation == CGPointZero` 的兜底是「a potentially dangerous assumption」 |
| 布局主权交给了物理引擎 | `layoutAttributesForElementsInRect:` 直接返回 `[animator itemsInRect:]`，与「engine 是唯一真值」正相反 |
| 规模对不上 | 原文说朴素版本只适用于 "a few hundred items"；本库基线是 10 万行 |

能拿走的只有一样东西：**权重按「离锚点的距离」线性上升、到 `resistanceFactor`
饱和**。这个形状是对的，剩下的整个重写。

### 1.1 API 形状的参考：CollectionKit / UIComponent 的 `Animator`

效果怎么做是一回事，**钩子长什么样**是另一回事。后者的最佳公开参考是
Luke Zhao 的 CollectionKit（★4.5k）里的 `Animator`，以及它的继任者
UIComponent 里被重新设计过的同名协议。演进本身信息量最大：

```
   CollectionKit (2017)                 UIComponent (2021→)
   ─────────────────────────────────────────────────────────────────────────
   open class Animator                  protocol Animator
     子类化，super.update() 可调           + extension 提供全部默认实现
                                          + struct BaseAnimator: Animator {}
                                            ← 一行就是一个完整实现

   insert / delete / update / shift     insert / delete / update / shift
                                          + willUpdate(hostingView:)
                                            ← 每趟一次，且只给根 animator

   update(cv:view:at:frame:)            update(hostingView:view:frame:)
                                          ← 索引参数被删掉了

   delete 里自己调 recycle              delete(…, completion:) 由调用方回收
```

`update` 的文档注释三条触发时机写得很清楚，第三条正是我们要的位置：

> Called when: the view has just been inserted / the view's frame changed after
> `reloadData` / **the view's screen position changed when user scrolls**

滚动特效就是这么写的，Example 里的 `ZoomAnimator` 全文如下：

```swift
open class ZoomAnimator: Animator {
  open override func update(collectionView: CollectionView, view: UIView, at: Int, frame: CGRect) {
    super.update(collectionView: collectionView, view: view, at: at, frame: frame)
    let bounds = CGRect(origin: .zero, size: collectionView.bounds.size)
    let absolutePosition = frame.center - collectionView.contentOffset
    let scale = 1 - max(0, absolutePosition.distance(bounds.center) - 150) / (max(bounds.width, bounds.height) - 150)
    view.transform = CGAffineTransform.identity.scaledBy(x: scale, y: scale)
  }
}
```

优雅在三件具体的事上：

```
   ① 全部方法都有默认实现，实现方只覆盖它在乎的那一个
      FadeAnimator 8 行，ScaleAnimator 继承它再 8 行，BaseAnimator 一行

   ② 不返回值 —— 把 view 交给实现方，它自己写
      没有「返回的 frame 算什么」这种契约问题

   ③ 方法按「场合」切分，不按「阶段」切分
      insert / delete / update / shift 各是一个语义事件，不是流水线的工位
```

①③ 照抄。②**只抄一半**：view 确实交给实现方，但「默认实现老实写 frame、
覆盖者先调 `super` 再叠自己」这个惯用法在我们这里抄不了，原因见 §7.2——
那正是第一版栽的地方。

其中 `shift(delta:)` 尤其值得注意——文档是
"Called when contentOffset changes during reloadData"，默认实现 `view.center += delta`。
**这就是我们的补偿问题**。第一版认定我们不需要这个钩子，那是错的（§7.3）。

有一样东西它没有、我们必须有：**「还要不要下一帧」的信号**。
CollectionKit 的滚动 animator 全是 `contentOffset` 的纯函数（无状态、无时间），
过渡动画则交给 `UIView.animate`，两者都不需要 display link。
我们的弹簧是时间驱动的有状态对象，必须能告诉列表「我还没停」。

---

## 2. 模型：一个标量弹簧 + 单边权重

### 2.1 为什么不是每行一个弹簧

每行一个弹簧（原型的做法）有个绕不开的成本：行在滚动中不断挂载和回收，
新进视口的行没有弹簧状态。原型里那段 "adjust the item's center in flight" 就是
在给这件事打补丁。

标量版本没有这个问题：状态是全局的一个 `S`，新行进来直接求值 `S · w(row)`，
不需要种子、不需要迁移、不需要跟着复用池走。状态从 O(可见行数) 降到 O(1)，
每帧只剩一次积分。**行的复位也因此是免费的**：回收一行只要把它的表现位移清零，
没有per-row 状态要销毁（§7.4）。

代价是把「各行独立的弹簧」近似成「同一根弹簧 × 各行不同的权重」。误差来源是
`w` 随时间变化（行相对锚点在移动），两种做法在这一点上误差同阶，不亏。

### 2.2 定义

```
   状态：S（当前拉伸量，pt）—— 一个 SpringInterpolation，target 恒为 0

   每帧：
       Δ  = 本帧可见滚动位移（已扣补偿，见 §3.3）
       Δ ← clamp(Δ, ±maximumStretch)     单帧注入上限，见 §2.3
       spring.setCurrent(spring.value + Δ, spring.velocity)
       spring.setTarget(0)
       spring.update(dt)                  dt 已上钳到 1/30
       若 |spring.value| > maximumStretch：
           spring.setCurrent(sign · maximumStretch, 0)    ← 写回状态，速度归零
       S = spring.value

   第 i 行的位移：
       c  = 该行中心的 y（内容坐标）
       a  = 锚点的 y（内容坐标）
       w  = ┌ min(1, |c − a| / resistanceFactor)   当 sign(c − a) == sign(S)
            └ 0                                    否则
       d(i) = S · w
```

两处相对第一版的修正，都是复核逼出来的：

**钳制必须写回弹簧状态，不能只钳表现值。** 第一版的伪码写了
`S ← clamp(...)`，但实现草图里 `willUpdate` 从没把钳过的值写回 `spring`。
两者的差别不是细节：只钳表现值的话，内部位置会在持续快滑时无上限地涨，
松手后要多花好几百毫秒才落回可见范围，而这段时间 `wantsNextFrame` 一直是 true——
屏幕上什么都没动，link 还在跑。写回状态则必须定义边界速度策略，取**归零**：
撞到上限就是「拉到头了」，继续累积速度没有物理意义。

**参数要校验。** `maximumStretch` / `resistanceFactor` 是 public var，
`resistanceFactor = 0` 会让 `w` 除零，负值和 NaN 会让 §2.3 的证明整个失效。
setter 里 clamp 到 `maximumStretch ∈ [0, 200]`、`resistanceFactor ∈ [1, 10000]`、
`angularFrequency ∈ [1, 500]`、`dampingRatio ∈ [0.1, 5]`，NaN 落回默认值。
不 `precondition`——这是外观参数，崩溃的代价大于兜底。

`w` 是**单边**的：只有 S 指向的那一侧滞后，另一侧钉死在真实几何上。
下一节说明这不是取舍，是几何上唯一可能的形状。

### 2.3 单边是被逼出来的，而且它让「不重叠」可证

原型是对称的：手指两侧都滞后，于是一侧的间隙被压缩、另一侧被拉开
（ScottLogic 叫它 "compression ahead, expansion behind"）。

本库的行是**连续的**——`offset(at: i+1) == offset(at: i) + height(at: i)`，
行与行之间没有几何间隙。**没有间隙可压缩。** 强行压缩就是行重叠，
`layoutContent()` 里那条 `assert(view.frame.minY >= previousMaxY)` 会直接打脸。
所以对称模型在这里表达不出来，只有拉伸那一半是有意义的。

单边权重把这件事变成一个可证的不变量：

```
   不重叠  ⇔  top(i+1) + d(i+1) ≥ top(i) + h(i) + d(i)
           ⇔  d(i+1) ≥ d(i)                    （代入 top(i+1) = top(i) + h(i)）

   S > 0（向下滚）：锚点上方 d = 0，下方 S·min(1,(c−a)/K) 随 c 单调增   → 非降 ✓
   S < 0（向上滚）：锚点上方 S·min(1,(a−c)/K) 越往上越负，下方 d = 0    → 非降 ✓
   |d| ≤ |S| ≤ maximumStretch，逐元素截断是单调映射，不破坏上式          → 非降 ✓
```

这一段独立复核过，成立，且**不依赖行高**——行高悬殊、零高度行、只露一半的行
都不破坏它，因为证明只用到「c 随 i 非降」和「w 随 |c−a| 非降」。

**但第一版关于方向反转的那句话是错的，必须收回。** 原文写：

> 方向反转时 `S` 过零，权重整体换边——但过零的那一刻 `|S| ≈ 0`，两侧位移都趋近 0，连续，不跳。

这是连续时间的说法。采样之后不成立：一帧里先做 `S += Δ` 再按新的 `sign(S)` 选边，
一个足够大的反向 Δ 可以让 S 直接从 +20 跳到 −20，**中间那个近零状态从来没有被渲染过**。
旧的一侧全部瞬间归零，新的一侧瞬间弹出。回弹和急停急反手都会碰到，不是病态输入。

处理办法是**限幅，不是消除**：单帧注入的 Δ 钳到 ±`maximumStretch`（§2.2），
于是过零时的最坏单帧跳变有界，且界就是 `maximumStretch` 本身。实践中远小于这个数，
因为真实的反转要先减速。这一条要写成 property test：合成一次符号翻转，
断言任意一行的 `d` 单帧变化量 ≤ `maximumStretch`——**断言的是有界，不是连续**。

所以这里不需要任何逐行钳制的后处理。行序不变是模型的性质，不是补丁。

### 2.4 视觉上长什么样

向下滚，锚点 `a` 落在第 i 行内部：

```
      真实几何                      加上位移之后
   ┌───────────┐                 ┌───────────┐
   │  row i-1  │                 │  row i-1  │   d = 0
   ├───────────┤                 ├───────────┤
   │  row i    │ ◀ a 在这一行里   │  row i    │   d ≈ 0，见下
   ├───────────┤                 ├───────────┤
   │  row i+1  │                 ╎           ╎   ← 间隙
   ├───────────┤                 ├───────────┤
   │  row i+2  │                 │  row i+1  │   d = S·0.3
   ├───────────┤                 ╎           ╎   ← 间隙
   │  row i+3  │                 ├───────────┤
   ├───────────┤                 │  row i+2  │   d = S·0.6
   │  row i+4  │                 ╎           ╎   ← 间隙
   └───────────┘                 ├───────────┤
                                 │  row i+3  │   d = S·1.0  ← 饱和
                                 ├───────────┤
                                 │  row i+4  │   d = S·1.0  ← 之后整体平移
```

**没有「锚点行」这个东西。** 第一版的图给 row i 标了 `d = 0`，那是把点锚点
当成了行锚点。公式判的是**行中心**相对锚点的位置：锚点只要不恰好落在 row i 的中心，
row i 自己就会动一点（`|c − a|` 是它中心到锚点的距离，通常是几到几十 pt，
除以 `resistanceFactor = 500` 之后是个小权重）。

这不破坏 §2.3 的证明——它只关心 d 随 i 非降——但它改变了承诺给用户的手感：
「手指按住的那一行纹丝不动」和「手指附近的行几乎不动」不是一回事。
两者都合理，但要**明确选一个**，跟 §5 的锚点选型一起在真机上定。

饱和之后的行整体平移，彼此之间没有新的间隙——`resistanceFactor` 决定了
「拉开的区域」有多深。

### 2.5 参数之间的关系（省一小时瞎调）

匀速滚动时弹簧会到稳态。第一版把回复力近似成 `S·ω·dt`，解出 `|S| ≈ v/ω`。
**这个近似漏了阻尼项**：`SpringInterpolation` 是二阶系统，同时演化位置和速度，
而我们每帧注入位移时保留了原速度。小步长下的平衡点是

```
   稳态拉伸  |S| ≈ 2ζ·v / ω          （ζ = dampingRatio）
```

临界阻尼（ζ = 1）下就是 `2v/ω`，是第一版估计的两倍。按原来的 `ω = 30`、
`v = 750`，稳态是 50pt 而不是 25pt——**默认参数会在常速滚动下直接顶到 24pt 上限**，
观感退化成「整屏平移」，`resistanceFactor` 的层次感全丢。

修正后：想让常速滚动（500–1000 pt/s）**刚好不饱和**，取

```
   ω ≈ 2ζ·v典型 / maximumStretch
   maximumStretch = 24, v = 750, ζ = 1  →  ω ≈ 62.5  →  取 60
```

两个参数管的不是同一件事：

- **`maximumStretch`** 管快滑。`v` 一大 `S` 就顶到上限，此时观感完全由它决定。
- **`angularFrequency`** 管慢滑和松手后的回落。

这个 60 是纸面推的，第 5 步真机确认。推导本身的价值不在于给出精确值，
而在于给出**依赖方向**：ω 翻倍则稳态减半，v 翻倍则稳态翻倍。调参时按这个走。

---

## 3. 一帧里发生什么

### 3.1 谁来 tick

现状（逐条核对过，第一版这里说得太满）：

```
   UIKit    scrollingDisplayLink 只在 scroll(to:) 的程序化滚动期间存在
            原生拖拽、惯性、回弹全部没有 ListViewKit 的 link
            —— 那些阶段只体现为 isTracking / isDragging / isDecelerating

   AppKit   物理是自己写的，回弹 / 惯性 / 程序化滚动都会建 link
            直接拖拽（scrollWheel 事件驱动）没有 link
```

两端的共同点只有一条：**直接拖拽期间没有 link**。「惯性和回弹都有 link」
只对 AppKit 成立，UIKit 那半是原生的，采样规则必须单独覆盖（§3.3）。

弹簧不能挂在 `layoutContent()` 上。两个原因：

```
   ① layoutContent() 一帧可能跑很多次
        主要来源是 apply / update / append 之后的 layoutNow() 同步重入；
        contentSize 写和 measureViewport 是通过标脏间接引发的，不是直接调用。
        无论哪条路径，按「布局跑了几次」积分弹簧，dt 都是错的。

   ② 手指按住不动时没有事件
        没有 offset 变化 → 不布局 → 弹簧冻在拉开的位置上，不回落
```

所以弹簧自己拥有一条 display link，与 `scrollingDisplayLink` 完全独立：

- UIKit：一条独立的 `CADisplayLink`。**不能用 `CADisplayLink(target: self,)`**——
  run loop 强引用 link、link 强引用 target，现有代码靠 `cancelCurrentScrolling()`
  的显式 invalidate 兜住，而这条 link 的存活由用户代码的 `wantsNextFrame` 决定，
  兜不住。用一个持有弱引用的私有 proxy 做 target。
- AppKit：`MSDisplayLink.DisplayLink` 只有一个 `delegatingObject`，第二条 link
  委派到同一个对象会跟滚动动画的回调撞在一起。同样需要私有转发壳。

**生命周期**（§7.5 的完整规则）：

```
   起：任何一次「可见滚动」写入 contentOffset 时（写入点判定，见 §3.3）
   续：wantsNextFrame == true，或账本里还有未消费的 Δ
   停：以上皆否，或 window == nil，或 ListView 从 superview 摘除
```

### 3.2 分工

**积分在 display link 上，落地在每次摆行之后。**

```
   一帧
   ├─ DisplayLink tick ────────────────────────────────────────────┐
   │    Δ = 账本累积的可见滚动量（写入时记的，见 §3.3），随即清零     │
   │    animator.willUpdate(context)        ← 唯一的一次状态推进     │
   │    列表照常 layout（如果这一帧需要）                            │
   │    applyRowAnimator()                  ← 对全部挂载行求值并落地  │
   └────────────────────────────────────────────────────────────────┘

        wantsNextFrame == false 且账本空 ──▶ 撤 link、位移清零、回到零开销
```

`layoutContent()` / `updateVisibleRowFrames()` **不积分**，但每趟结束时都要跑一次
`applyRowAnimator()`——否则一次中途的布局会把行瞬间弹回未位移的位置。

### 3.3 采样规则：判定在写入点，不在 tick 点

第一版的规则是「tick 的时候看 `isUserInteractingWithScroll || scrollingDisplayLink != nil`，
是就采样」。这条是错的，因为**这两个状态可以在 tick 之前就结束**：
最后一段拖拽位移会被整个丢掉（松手后状态先转 false，link 才回调），
反过来一次 idle 期的跳转也可能因为紧接着开始了拖拽而被误采。

终版把判定挪到写入点，列表自己记一本账：

```
   ListScrollView 内部
       var animatorScrollLedger: CGFloat = 0     // 未被 tick 消费的可见滚动量

   每一处改写 contentOffset 的地方显式分类：
       用户拖拽 / 惯性 / 回弹 / 程序化滚动     ──▶ ledger += dy，并唤醒 link
       compensateScrollOffset(by:)             ──▶ 不入账，改调 rebase（§7.3）
       reconcileOffsetWithContentSize          ──▶ 不入账
       setContentOffset(_:animated: false)     ──▶ 不入账

   tick：Δ = ledger; ledger = 0
```

UIKit 那边「用户拖拽 / 惯性」没有自己的 link，落在 `scrollViewDidScroll` 上，
此刻同步读 `isTracking || isDragging || isDecelerating` 是准的——
它和错误版本的区别不在谓词，在**求值时机**。

这样做还顺手解决了启动问题：第一版里 `wantsNextFrame` 静止时是 false，
而只有 tick 才会注入 Δ，于是**没有任何东西能点燃第一帧**。
入账即唤醒之后，link 由列表点火、由 animator 决定何时熄火。

---

## 4. 位移怎么落地

第一版的答案是「一律走 layer transform，因为这样 `view.frame` 保持等于 engine 真值」。
**这个理由是假的。** UIKit 文档写得很明白：transform 非单位阵时 `frame` 未定义。
而 `updateFrame` 的第一句就是 `guard rowView.frame != targetFrame else { return }`，
DEBUG 那条重叠断言读的也是 `view.frame`。挂上 transform 之后，每趟布局都会认为
所有行都偏离了目标，断言也不再检查静止几何。整条论证反了。

终版分成两件事。

### 4.1 真值通道：`placedFrame`

`ListRowView` 上加一个显式的真值字段：

```swift
open class ListRowView {                    // 它本来就是 open，子类要能读到
    /// engine 说这一行在哪。只有列表写，animator 的位移不改它。
    public internal(set) var placedFrame: CGRect = .zero
}
```

`internal(set)` 而不是 `private(set)`：写它的是 `ListView` 和 `Animation.swift`，
不在同一个文件；而它对子类和使用方都必须只读。

- `place(at:)` 写 `placedFrame`，并把行摆过去。
- `updateFrame` 的短路判断改成比 `placedFrame`。
- DEBUG 那条重叠断言改成对 `placedFrame` 断言——它查的本来就该是布局的正确性，
  不是表现层的正确性。
- `recycleRowsOutsideViewport` 比的是 `rectForRow(at:)`，本来就没读 view，不受影响。

有了这一层，位移走哪个通道就变成纯粹的平台工程问题，不再牵动布局不变量。

### 4.2 表现通道：两端分流

选择标准只有一条：**跟这个平台自己的动画机制能不能叠加**。
列表的 reorder 动画和弹簧位移会同时在跑，谁都不能覆盖谁。

```
   UIKit    layer transform 的平移
            reorder 走 UIView.animate 动 position；transform 是另一条 key path，
            两者天然正交。命中测试在 UIKit 下会穿过 transform，正确。

   AppKit   frame 偏移（写 placedFrame + d）
            NSView 的命中测试和无障碍走的是 frame，不认 backing layer 的 transform；
            翻转坐标下 CA 的 Y 方向也未必和视图坐标一致。
            而 Animation.swift 那条 additive CASpringAnimation 动的是 position 的
            「增量」，与我们写进去的模型值无关 —— 我们每帧改模型位置，
            它继续贡献自己那条衰减到零的曲线，叠加成立。
```

两端都收在一句 `ListRowView.setPresentationOffset(_:)` 里，实现方看不到这个分叉。
批量写包在 `CATransaction(setDisableActions(true))` 里，防止隐式动画把 60Hz 的
位移变成一串 0.25s 的插值。

**第一版把 AppKit transform 列成「风险，第 2 步实测」。那是拿一个公开 API 的
可行性去赌一次实测。** 终版不赌：AppKit 直接走 frame，因为它和加性动画的
叠加性质是可以推出来的，不需要试。

---

## 5. 锚点

```
   UIKit   panGestureRecognizer.location(in: self).y
           手势结束后它保留最后一次触点，比原型的 CGPointZero 兜底好

   AppKit  window.mouseLocationOutsideOfEventStream 转到本视图坐标
           触控板没有触点，光标是唯一可用的近似

   两端    指针不在 bounds 内时 ──▶ 退回「行进方向的后缘」
           即向下滚取视口顶边、向上滚取视口底边，整个视口都参与拉伸
```

锚点全部收敛到一个函数 `anchorY(for stretch: CGFloat) -> CGFloat`。
指针锚点和后缘锚点观感差别不小（前者只有指针那一侧拉伸，后者整屏拉伸），
**这件事靠看，不靠推理**：第 4 步在 Example 里加开关，真机上选，
连同 §2.4 那个「指针所在行到底动不动」一起定，选完再决定要不要提升成公开配置。

锚点是内容坐标里的一个值，所以它和补偿有关系——见 §7.3。

---

## 6. 视口矩形要拆成两个

行按 `indices(intersecting: contentVisibleRect)` 挂载。位移最多
`maximumDisplacement`，所以一个刚出视口的行可能被拉回屏幕内，而它已经被回收了。
需要外扩。

第一版说「把 `contentVisibleRect` 外扩就行，挂载和测量一起扩」。
**这条会撞坏补偿。** 复核发现这个矩形被四处共用，语义并不相同：

```
   ListView.swift:324          measureRows(intersecting:)     ← 内部要算补偿锚点
   ListView+SliceDrain.swift:80 drainPendingRows(intersecting:) ← 同上
   ListView.swift:408          prepareVisibleRows()           ← 挂载
   ListView+API.swift:22       indicesForVisibleRows          ← 公开语义「在屏上」
```

补偿的锚点是「第一个起点落在**真实视口**内的行」。矩形往上扩之后，
一个本来在视口上方的行会被算成「视口内」，它的高度变化就不再产生补偿——
**真实视口会跳**。这不是多挂一行的小事。

终版拆成两个概念：

```
   viewportRect          真实视口。补偿锚点用它、公开的 indicesForVisibleRows 用它。
                         就是今天的 contentVisibleRect，语义不变。

   mountRect             viewportRect 上下各扩 maximumDisplacement。
                         挂载用它、回收用它、测量覆盖用它。
                         animator 为 nil 时 == viewportRect，走今天的路径。

   测量签名改成           measureRows(intersecting: mountRect, anchoredAt: viewportRect)
                         覆盖范围扩、锚点不扩。drainPendingRows 同理。
```

外扩量是**恒定**的 `maximumDisplacement`，不随 `S` 变——否则挂载集合会跟着弹簧
呼吸，每帧 churn。

### 6.1 顺带发现：回收和挂载用的不是同一个矩形，但今天恰好等价

```swift
// ListView.swift:477，回收           —— 滚动坐标系
let visibleRect = CGRect(origin: contentOffset, size: bounds.size)
rectForRow(at: index).intersects(visibleRect)      // rectForRow 自己 += topInset

// ListView.swift:255，挂载           —— 行坐标系
var contentVisibleRect: CGRect {
    .init(origin: .init(x: contentOffset.x, y: contentOffset.y - topInset), size: bounds.size)
}
rowLayout.indices(intersecting: contentVisibleRect)
```

**本文第一版断言这里差一个 `topInset`，是现存 bug。实测推翻了。**
两个矩形的数值确实差 `topInset`，但比较对象也差同一个 `topInset`——
回收侧的 `rectForRow(at:)` 会自己加上去（`ListView+API.swift:32`），
挂载侧的 `rowLayout.frame(for:)` 不加。两次一抵，选出来的行严格相同：

```
inset=60   mountRect=(0,440,200,200)   recycleRect=(0,500,200,200)
           mounted=[4,5,6]             kept=[4,5,6]        diff=[]
```

所以第 0 步不是 `fix:` 而是 `refactor:`，**没有行为变更**。
它要消灭的是「靠抵消成立」这件事本身——第 4 步一旦把 `mountRect` 外扩，
抵消立刻不成立，而且失败是静默的：回收掉的行当趟就会从池里挂回来，
`visibleRows` 的集合稳定、`removeFromSuperview` 也不会被调用
（同趟复用的 view 不会被摘），唯一能观测到的是**行被重复 `configure`**。
第 0 步的测试就断言这一条。

### 6.2 成本：给的是距离界，不是行数界

第一版写「24pt 每边最多多挂一行」。假的——行高被归一化成任意非负整数，
包括 0。24pt 里可以塞进几十个 1pt 的行，或者任意多个零高度行，
而 `indices(in:)` 会一路走到扩后的边界。

正确的说法是：**外扩的成本是 O(该 24pt 区间内的行数)**，不是 O(1)。
典型场景（消息列表，行高 40–200pt）确实是每边 0–1 行；
零高度或极薄行密集的列表要自己承担这个成本。写进 `maximumDisplacement` 的文档。

---

## 7. API：`ListRowAnimator`

把「行摆好之后再动一下」开成扩展点，弹簧就不再是内置特性，而是内置的一份实现。

```swift
/// 在列表把行摆到 engine 算出的位置之后，叠加表现层的变化。
///
/// 这不是布局：几何已经定了，是入参。位移不改变 `placedFrame`，
/// 不影响测量、补偿、命中范围之外的任何东西。
/// 所有方法都有默认实现，只覆盖在乎的那一个即可。
@MainActor
public protocol ListRowAnimator {
    /// 每帧一次，在这一趟的所有 `update` 之前。有内部状态要按时间推进的，
    /// 在这里推进。只有 display link 的 tick 会调它（§7.1）。
    mutating func willUpdate(_ context: ListAnimatorContext)

    /// 某个挂载行这一帧长什么样。行已经在 `frame` 上了；这里只叠加。
    /// 默认什么都不做。
    func update(row: ListRowView, at index: Int, frame: CGRect, in context: ListAnimatorContext)

    /// 内容坐标被整体平移了 `delta`，但屏幕上什么都没动（§7.3）。
    /// 存了内容坐标状态的实现在这里重新基准化。默认什么都不做。
    mutating func rebase(byContentOffset delta: CGFloat)

    /// 回到静止状态。列表在 animator 被替换或置 nil 之前调一次。默认什么都不做。
    mutating func reset()

    /// 还需要下一帧吗。为 true 时列表保持 display link 活着；
    /// 为 false 且滚动账本为空才撤掉、清空位移、回到零开销。默认 false。
    var wantsNextFrame: Bool { get }

    /// `update` 造成的最大**纵向平移**，用于恒定外扩挂载矩形（§6）。默认 0。
    /// 每趟布局读一次，改动下一趟生效。
    /// 只约束平移：缩放、旋转等超出这个量的效果会在边缘被裁掉。
    var maximumDisplacement: CGFloat { get }
}

public extension ListRowAnimator {
    mutating func willUpdate(_ context: ListAnimatorContext) {}
    func update(row: ListRowView, at index: Int, frame: CGRect, in context: ListAnimatorContext) {}
    mutating func rebase(byContentOffset delta: CGFloat) {}
    mutating func reset() {}
    var wantsNextFrame: Bool { false }
    var maximumDisplacement: CGFloat { 0 }
}

public struct ListAnimatorContext {
    /// 真实视口，内容坐标（不是 mountRect）。
    public let viewportRect: CGRect
    /// 本帧可见滚动位移，写入时记账、tick 时消费（§3.3）。
    public let scrollDelta: CGFloat
    /// 已上钳到 1/30。
    public let deltaTime: TimeInterval
    /// 指针在内容坐标里的 y，取不到时 nil（§5）。
    public let pointerY: CGFloat?
    public let isUserInteracting: Bool
    /// 列表自己的动画（reorder / insert / delete）正在跑。
    public let isListAnimating: Bool
}

public extension ListView {
    /// nil 关闭，且是默认值。关闭时滚动路径上一行代码都不跑。
    /// 赋新值前，列表会对旧值调 `reset()` 并清空所有行的表现位移。
    var rowAnimator: (any ListRowAnimator)? { get set }
}
```

内置实现：

```swift
@MainActor
public struct ListScrollSpring: ListRowAnimator, Equatable {
    public var maximumStretch: CGFloat = 24      // setter 校验，见 §2.2
    public var resistanceFactor: CGFloat = 500
    public var angularFrequency: Double = 60     // 见 §2.5，第一版是 30
    public var dampingRatio: Double = 1

    private var spring = SpringInterpolation(...)
    private var anchorY: CGFloat = 0

    public var maximumDisplacement: CGFloat { maximumStretch }
    public var wantsNextFrame: Bool { !spring.completed }

    public mutating func willUpdate(_ context: ListAnimatorContext) {
        let delta = context.scrollDelta.clamped(to: -maximumStretch ... maximumStretch)
        spring.setCurrent(spring.value + delta, spring.context.currentVel)
        spring.setTarget(0)
        spring.update(withDeltaTime: context.deltaTime)
        if abs(spring.value) > maximumStretch {                 // 写回状态，速度归零
            spring.setCurrent(spring.value.sign * maximumStretch, 0)
        }
        anchorY = context.pointerY ?? trailingEdge(of: context)
    }

    public func update(row: ListRowView, at index: Int, frame: CGRect, in context: ListAnimatorContext) {
        row.setPresentationOffset(displacement(for: frame))     // 只叠加，不摆放
    }

    public mutating func rebase(byContentOffset delta: CGFloat) {
        anchorY += delta                                        // 见 §7.3
    }

    public mutating func reset() {
        spring.setCurrent(0, 0)
    }

    public static let messages = Self()
    public static let subtle = Self(maximumStretch: 12, resistanceFactor: 800, angularFrequency: 120)
}

list.rowAnimator = ListScrollSpring.messages
```

不标 `Sendable`：存着的 `SpringInterpolation` 本身没有 `Sendable` 一致性，
硬加会编译不过；而 `@MainActor` 隔离已经给了它需要的那种安全性。
包是 Swift 6 严格并发，`update` 要同步调 main-actor 的行 API，
所以**协议必须是 `@MainActor`**，不能是无隔离的。

默认关闭，是为了不给 3.0 刚拿到的滚动数字（100k 行 20k offset writes 21ms）
增加任何回归风险。

### 7.1 相位分离：结构上有用，但不是类型系统保证的

`willUpdate` 每帧一次、`update` 每行一次，中间不允许状态推进。这一点让实现方
不必判断「这是不是新的一帧」，也就没有忘记判断的可能。第一版说这是
「类型系统本身在说这件事」——**说过头了**：`update` 是非 mutating 的，
但 class 实现可以随便改自己的存储，struct 也可以改引用类型里的东西。
`updateVisibleRowFrames(animated:)` 还会被 `apply(animated: true)` 在非 tick 时调到。

准确的说法：值类型 + `mutating` 只在 `willUpdate` 上，是一条**很强的暗示和一道
默认防线**，不是证明。真正的保证来自列表这一侧——只有 tick 会调 `willUpdate`，
这条写进文档注释，并在第 5 步用 `animatorTickCount` 计数器测出来。

UIComponent 在 CollectionKit 之上补了一个 `willUpdate(hostingView:)`，
是同一个结论：这一相值得有自己的入口。

### 7.2 为什么默认实现是空的（第一版这里错了）

第一版照 CollectionKit 抄了「默认实现老实写 frame，覆盖者先调默认再叠自己」，
于是要把 `ListRowView.place(at:)` 公开出去当 `super` 用。有两个问题：

**一，签名里没有 `animated`。** `updateVisibleRowFrames(animated:)` 把这个标志
一路传到 `setRowFrame`，`Animation.swift` 开篇第一条规则就是「列表只动画它说要
动画的东西——一次列表更新经常跑在别人的动画块里，所有权必须显式传递，
不能读环境」。`update` 拿不到这个标志，`place(at:)` 就只能猜：
猜「不动画」会杀掉 reorder，猜「动画」会违反那条所有权规则。

**二，钩子位置在短路判断的里面。** 第一版说钩子在
「`rectForRow` 和 `setRowFrame` 中间」，但那里是
`guard rowView.frame != targetFrame else { return }` 的后面——frame 没变的行
永远拿不到 animator，而新挂载的行在 `ensureRowView` 里已经被 `placeView` 摆好了，
会有一帧没有位移。

两个问题同一个根因：**把 animator 塞进了「摆放」这条路径**。
终版把两件事分开：

```
   列表负责摆放         updateFrame / ensureRowView，照旧，animated 照旧传
   animator 负责位移    layoutContent() 末尾统一跑一次 applyRowAnimator()，
                       无条件遍历全部挂载行，不受任何短路判断影响
```

于是 `update` 的默认实现是**空的**，`animated` 的问题不存在，
`super` 的需求不存在，新挂载的行和 frame 没变的行都会被覆盖到。
`place(at:)` 仍然公开（给将来想整个重定位一行的实现），但默认路径不需要它。

代价是失去了 CollectionKit 那个「一个方法既能改也能不改」的统一感——
换来的是不用给公开 API 塞一个连列表自己都不好回答的 `animated` 参数。

### 7.3 补偿：终版有 `rebase`，第一版说不需要是错的

第一版的论证是：CollectionKit 的 `shift(delta:)` 存在是因为它们的补偿要移动 view，
而我们的 `compensateScrollOffset(by:)`「只动 contentOffset」，
所以只要在 `scrollDelta` 里替实现方扣掉就行。

两处不对。

**措辞不准。** 它不止动 `contentOffset`：UIKit 侧还平移程序化滚动的目标和弹簧状态，
AppKit 侧还平移原始触摸基准、惯性起点、回弹目标、程序化目标和弹簧状态。
（顺带：UIKit 没法平移 `UIScrollView` 私有的拖拽/减速状态，所以
「所有在途状态都被补偿」只对 AppKit 自己那套物理成立。）

**结论不对。** 就算只动 `contentOffset`，**内容坐标系本身被平移了**。
弹簧存了一个内容坐标里的值——`anchorY`。补偿之后这个值还停在旧坐标系里，
下一次 `update` 求出来的权重整体偏移，屏幕上就是一跳。
`scrollDelta` 扣掉只解决了「别把瞬移当成滚动喂进弹簧」，没解决「存量状态要跟着搬家」。

所以协议里有 `rebase(byContentOffset:)`，默认空实现，弹簧里就一句 `anchorY += delta`。
形状和 CollectionKit 的 `shift` 一致，但语义更窄：我们搬的是 animator 的状态，
不是 view——行的 `placedFrame` 在补偿中确实一动不动，那部分第一版说对了。

**相关但未解决：切片测量期间行高变化。** `measure(at:)` 会当场改行高，
只有测量锚点上方的部分产生补偿。一个可见行长高或变矮会改变它自己以及它之后
所有行的中心，权重可以在没有任何滚动的情况下跳变最多一整个 `maximumStretch`。
`rebase` 管不了这个——它是坐标系平移，这是几何重排。
处理办法：把「一趟布局里权重的最大变化量」作为 §8 第 2 步的观测指标，
在 Example 的变高列表上实测；如果肉眼可见，再考虑给权重本身加一个短时低通。
**不提前加**——那是给一个没证实存在的问题写代码。

### 7.4 复位契约

第一版完全没写。三个场合：

```
   行被回收            recycleRow 里紧挨 cancelRowAnimations 调一次
                      row.setPresentationOffset(.zero)
                      —— 否则复用给下一个 item 时带着上一个的位移
                      标量模型让这一步是免费的：没有 per-row 状态要销毁（§2.1）

   animator 被替换/置 nil  列表先对旧值 reset()，再遍历全部挂载行清零位移，
                      再撤 link、清空账本。新值从干净状态开始。

   link 熄火          最后一次 update 之后统一清零，保证「静止时零残留」
                      —— 第 5 步的测试直接断言这一条
```

### 7.5 生命周期与防呆

`update` 是公开的每帧路径，进来的是用户代码。四条防线：

```
   拆除     window == nil / 从 superview 摘除 / deinit ── 一律撤 link
            UIKit 的 CADisplayLink 用弱引用 proxy 做 target，不用 self（§3.1）

   跑飞     wantsNextFrame 恒为 true 就是一个永不停的 120Hz 循环。
            不强制中止（可能是合法的持续动效），但 DEBUG 下连续 N 秒
            wantsNextFrame == true 且所有位移都为零时 Logger.warning 一次。

   重入     update 里回调 apply / 改 rowAnimator / 触发布局，会在遍历
            visibleRows 时改动它。落地时先把 (index, row, frame) 快照成数组再遍历；
            并置一个 isRunningRowAnimator 标志，让重入的 layoutNow() 降级成
            requestLayout()，推到下一趟。

   慢       照 ListRowLayout.slowRowThreshold 的现成做法，DEBUG 下超预算告警一次，
            把成本指回调用方。
```

### 7.6 `maximumDisplacement` 的边界

它是个活 getter，class 实现可以随时改大而不通知列表；一个纵向标量也框不住
缩放、旋转、按行高展开这类效果。两条路：收窄成纯平移，或者定义一套会被校验的
bounding insets 加失效通知。

**选收窄。** 文档写死「只约束纵向平移；超出的部分在边缘会被裁掉或不挂载」。
列表每趟布局重读一次，改动下一趟生效——因为挂载发生在布局里，不在 tick 里，
所以不需要额外的失效机制。想做 cover flow 的人得自己接受边缘裁切，
或者等一个真正需要它的实现出现时再来设计 insets 版本。
这条是**明确的能力边界，不是遗漏**，写进协议注释。

### 7.7 公开 API 的语义变化

`visibleRowViews` 和 `rowView(for:)` 返回的是挂载集合，外扩之后会包含
真实视口之外的行。而 `rowView(for:)` 的文档注释现在写的是
"if it is on screen"——外扩之后这句话是假的。

`indicesForVisibleRows` 用 `viewportRect`，语义不变。所以启用 animator 之后，
这两组 API 会不再等价。改文档注释，并在 §8 第 4 步的 release note 里写明。
不改行为：挂载集合本来就是实现细节意义上的「在屏」，收紧它会牵动复用逻辑。

### 7.8 现在不做、但形状要留出来的：insert / delete

CollectionKit 的 `Animator` 还管插入和删除动画。ListViewKit 已经有这套代码，
只是散在别处：`Animation.swift` 的 `withListAnimation` / `setRowFrame`、
`ListView+Disposal.swift` 的 `animateDisposal(of:)`、`apply` 里那段
`setAlpha(0, onRowWith:)`。

它们和 `update` 是同一个扩展点的不同场合。照 CollectionKit 的划分，
终局是 `insert` / `delete` / `update` 三个方法，现有行为成为默认实现。
`animated` 那个参数的问题也会在那一步被正面解决——因为 `insert` / `delete`
本来就是「列表自己的动画」这个语境。

**本文不做**——那是一次独立的重构，牵动 `apply(animated:)` 的整条路径。
但命名按这个终局来定，这就是协议叫 `ListRowAnimator` 而不是
`ListPlacementAdjuster` 的原因。

### 7.9 其它几个决定

**协议不泛型化。** 带上 `Item` 就变成 `ListRowAnimator<Item>`，实现之间没法复用
也没法组合。代价是它看不到 item 本身，只看得到 index 和真实 frame——对位移类效果够用。

**存在类型在这里是可以的。** DESIGN.md 对 `any` 的敌意针对的是 10 万行的路径。
这里是每帧 ~15 次，120Hz 下不到 2000 次/秒。这条要写进注释，
否则下一个读 DESIGN.md 的人会以为是疏忽。

**值类型。** 弹簧的状态是两个 Double，struct 存在 ListView 里，
没有循环引用、没有弱引用舞蹈、可以直接对拍测试。存在 `any` 里通过 mutating
requirement 调用，原地修改的值语义是成立的（这一条单独确认过）。

**列表替实现方扛下所有做账。** 写入点分类、补偿的扣减与 rebase、dt 上钳、
挂载矩形外扩、link 生命周期、相位切分、行回收时的清零——实现方只看到一个
干净的 `scrollDelta` 和一个可选的 `rebase`。这是这个钩子存在的意义：
如果每个实现都要自己处理 `compensateScrollOffset`，它就是个陷阱而不是扩展点。

**§2.3 的不重叠从「可证」退化成「契约」。** 实现方直接写 view，想让行重叠随时可以。
不打算强制钳制——层叠、视差这类效果重叠就是目的。
DEBUG 那条断言改查 `placedFrame`（§4.1），所以它继续在布局真值上工作，
既不会因为位移误报，也不再能捕捉位移造成的重叠。这是有意的分工。
内置的 `ListScrollSpring` 依然可证不重叠。

---

## 8. 落地顺序

一步一个 commit。**协议放到第 3 步才定型**，理由见下。

```
  #  commit                                  产出
 ──────────────────────────────────────────────────────────────────────────
  0  refactor: 统一回收与挂载的视口矩形         §6.1，无行为变更（实测确认）
                                              回收改读 contentVisibleRect，
                                              消灭「靠 topInset 两次相消才等价」
                                              测试：topInset 非零时重复布局
                                                    不重复 configure 已挂载的行
                                                    （注入错位可复现失败）

  1  feat: 弹簧纯模型                          不 import UIKit/AppKit 的 struct
     标量弹簧 + 单边权重 + 参数校验            property test：
     钳制写回状态、单帧注入限幅                 · 任意初态都收敛到 0
     此时还是 internal，不承诺任何形状          · |d| ≤ maximumStretch
                                              · d(i) 对索引非降（§2.3 的不变量）
                                              · 符号翻转时单帧 |Δd| ≤ maximumStretch
                                                （有界，不是连续 —— §2.3）
                                              · 内部状态不超过 maximumStretch
                                              · 非法参数（0/负/NaN）不破坏以上任何一条
                                              · dt 上钳到 1/30 后仍收敛

  2  feat: display link + 位移落地             写入点记账、link 生命周期与弱 proxy、
     placedFrame 真值通道                      UIKit transform / AppKit frame 分流、
     applyRowAnimator 统一落地点               CATransaction 批写
                                              测试（仿 ListViewScrollAppKitTests）：
                                              · 静止后位移归零、link 撤掉、账本为空
                                              · 补偿期间 S 不动，anchorY 跟着搬家
                                              · 一帧内多次 layout 只积分一次
                                              · placedFrame 全程等于 rectForRow
                                              · 移出 window 后 link 撤掉
                                              观测：一趟布局里权重的最大变化量（§7.3）

  3  refactor: 抽出 ListRowAnimator            协议 / ListAnimatorContext 定型
     弹簧成为它的第一份实现                     Example 里同时写第二份（视差或层叠），
                                              用它来验协议形状 —— 特别是验
                                              rebase / reset / maximumDisplacement
                                              这三个是不是真的够用

  4  feat: ListView.rowAnimator 公开           viewportRect / mountRect 拆分、
                                              Reduce Motion、复位契约、重入防护、
                                              rowView(for:) 文档注释修正（§7.7）、
                                              Example 参数面板，
                                              真机 + 触控板定锚点、定「指针那行动不动」、
                                              确认 ω = 60（§2.5 是纸面推的）

  5  perf: 回归确认                            关闭时 benchmark 与现基线一致；
                                              animatorTickCount 计数器
                                              （对标 scrollerGeometryPassCount），
                                              证明闲置时一次都不 tick、
                                              且每帧只 willUpdate 一次

 ────────────────────────────────────────────────────────────────────────────
  6  refactor: insert / delete 并入协议         §7.8，独立一次重构，本文不承诺
```

### 为什么协议不在第 1 步就定

**一份实现推不出协议。** 只照着弹簧设计，`ListAnimatorContext` 里会塞满弹簧
恰好需要的字段，而漏掉别的效果必需的东西——视差需要行在视口里的归一化位置，
层叠需要知道自己是不是第一个可见行。这些在写第二份实现之前是想不全的。
CollectionKit 的 `Animator` 有四个方法，是四年里被四类效果逼出来的。

这一版的经历本身就是证据：`rebase` 和 `reset` 是复核逼出来的，
第一版凭推理认定不需要 `rebase`，理由写得头头是道，结论是错的。
第 3 步要求先有第二份实现顶着，就是为了让形状被现实逼出来而不是被论证推出来。

代价是零：第 1、2 步弹簧作为内部实现照样能跑通、能测、能在真机上看效果，只是不 public。

这条对这个仓库尤其重要——3.0 刚把公开类型从 9 个砍到 4 个，
现在要往回加一个协议，值得多花一步确认它是对的。

---

## 9. 风险

| 风险 | 处理 |
| --- | --- |
| 第 4 步外扩 `mountRect` 时回收与挂载重新错位，且失败是静默的 | 第 0 步先统一到同一个矩形；测试断言「不重复 configure 已挂载的行」，这是唯一能观测到错位的量（§6.1） |
| UIKit 用 transform 而 `frame` 因此失真 | `placedFrame` 是布局唯一真值，短路判断和 DEBUG 断言都改查它（§4.1） |
| 两端位移通道不同，行为漂移 | 收在 `setPresentationOffset(_:)` 一个函数里；第 2 步两端各一套同名测试 |
| 锚点用指针在触控板上不成立（光标未必在用户注意力所在） | 第 4 步真机选型；后缘锚点是随时可切的备选 |
| 挂载矩形外扩的成本不是 O(1) | 给的是距离界不是行数界（§6.2），写进 `maximumDisplacement` 文档 |
| 切片测量改行高，权重无滚动跳变 | 第 2 步先观测再决定要不要低通（§7.3）；不提前写代码 |
| 符号翻转时位移单帧跳变 | 限幅到 `maximumStretch` 并写成 property test；承认是有界不是连续（§2.3） |
| 用户实现让 `wantsNextFrame` 恒真 | 不强制中止；DEBUG 告警 + 脱窗/摘除时无条件撤 link（§7.5） |
| 用户实现在 `update` 里重入列表 | 快照后遍历 + `isRunningRowAnimator` 让重入的 `layoutNow()` 降级（§7.5） |
| 结构变更（insert/remove）在滚动中发生，权重按新索引求值 | 权重只依赖行的 y 和锚点 y，不依赖索引身份，天然无缝 |
| 协议一旦公开就是永久 API，而 3.0 刚把公开类型 9 个砍到 4 个 | 第 3 步才定型，且要求先有第二份实现顶着；前两步弹簧是 internal |
| `maximumDisplacement` 框不住非平移效果 | 明确收窄成平移，写进注释当能力边界，不假装通用（§7.6） |
| 效果本身可能已经不存在于当代 Messages.app | 未能证实其去留；这是复刻一个 iOS 7 的手感，做成默认关闭的可选项 |
