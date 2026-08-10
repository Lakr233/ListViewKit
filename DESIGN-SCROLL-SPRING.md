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

处理办法是**限幅，不是消除**：过零时的最坏单帧跳变有界，界就是 `maximumStretch`。
这一条写成了 property test：合成符号翻转，断言任意一行的 `d` 单帧变化量
≤ `maximumStretch`——**断言的是有界，不是连续**。

**本文原先为此加了「单帧注入 Δ 钳到 ±maximumStretch」，落地时删掉了。**
故障注入证明它不承重：去掉它，全部 18 条测试照样全绿。原因是这个界由另外两条
性质联合给出，与注入量无关——状态钳制（§2.2）把 `|S|` 压在预算内，而**单边权重
让任何一行都只读得到一个符号的 S**（另一侧恒为 0）。所以一行的 `d` 只在
`[0, +max]` 或 `[−max, 0]` 里动，从来不会经历 `−max → +max` 那种 2 倍摆幅。
注入限幅防的是一个由别处保证的不变量。删了。

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
除以 `resistanceFactor`（实测取 120，见 §2.5.1）之后是个小权重）。

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

**落地时实测了，`2ζv/ω` 是上界不是等式。** 每帧注入位移再做一次离散松弛会欠松弛，
帧率越低欠得越多：默认参数、v = 600 pt/s 下，公式给 20pt，模型给

```
   120Hz   17.5 pt   （公式的 87.5%）
    60Hz   15.0 pt   （公式的 75.1%）
```

所以**同一个手势在 60Hz 屏上比 120Hz 松约 14%**。差值小到不值得补偿——要补就得把
注入改成与 dt 无关的形式，那会牵动整个积分器——但大到不该等以后偶然发现，
已经用测试钉住这两个比值。

依赖方向照旧：ω 翻倍则稳态减半，v 翻倍则稳态翻倍。

### 2.5.1 实测：ω = 60 是错的，整段推导的方向也是错的

上面那套「让常速滚动刚好不饱和」的推导，被一段 macOS Messages 的录屏推翻了。

量法：逐帧跟踪会话里的气泡边界，取相邻两行之间的**间隙**随时间的变化——间隙是
差分量，不受整体滚动干扰，也不受积分漂移影响。取两次手势（会话里不同位置）的
松手段，各自对二阶响应做最小二乘：

```
   手势 C   ω = 19.0   ζ = 0.74   峰值 15.6pt   rms 0.55px（10 个采样点）
   手势 A   ω = 21.0   ζ = 0.60   峰值 12.4pt   rms 1.32px（ 8 个采样点）
```

两次独立手势落在同一处，所以默认值取 **ω = 20、ζ = 0.75**，`maximumStretch = 20`
（实测单条缝最大张开 25–36px ≈ 11–15pt，按 `pitch/R ≈ 0.65` 反推预算 20pt），
`resistanceFactor = 120`（78pt 行距下相邻两行差 0.65 个预算，与录屏里「张开集中在
锚点附近一两行、远场整体平移」一致）。

原来的 ω = 60 **快了三倍**；原来的 `resistanceFactor = 500` 在 78pt 行距下相邻两行
只差 3.7pt，肉眼近乎没有层次。两个方向都错了。

推导错在哪：它要求常速滚动**不饱和**，理由是饱和就退化成整屏平移、丢掉梯度。
录屏说 Messages 就是饱和的——整段录像里远场始终作为一个刚体平移，全部张开都挤在
靠近锚点的一两行里。饱和不是退化，是那个观感本身。按实测参数，约 250 pt/s 以上
一律顶满预算，手势之间变化的是**预算被占用多久**，不是被占用多少。

这段录屏能支持的到此为止：ζ 和 ω 只由半衰期约束，而半衰期只认 ζω 的乘积，
所以单靠它分不开两者——是「回弹幅度 ≤ 峰值 8%」（实测 3% 和 0%）把 ζ 卡在 0.75
附近的。空间衰减律（`min(1, d/R)` 到底对不对）**没有**被这段录屏验证：60Hz 窗口
录制加上未知的行结构，只够定出「张开集中在一两行、远场刚体」这个量级，定不出函数
形状。测试 `theDefaultsRelaxLikeTheRecordingTheyWereFittedTo` 钉住的是半衰期和回弹
幅度，不是整条曲线。

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

### 3.4 熄火判据不能用 `SpringInterpolation.completed`

本文两处写过 `wantsNextFrame: Bool { !spring.completed }`。读了依赖的源码之后
这条不能要：

```swift
// SpringInterpolation+Context.swift
var completed: Bool {
    abs(context.currentPos.distance(to: context.targetPos)).isLessThanOrEqualTo(config.threshold)
}
```

**只比位置，不看速度。** 欠阻尼的弹簧全速穿过零点的那一帧，位置恰好落在
`threshold` 带里，`completed` 就是 true——而「到达静止」正是我们把状态清零的时机，
于是弹簧在第一次过零时被当场掐死。

这个坑的阴险之处在于**默认帧率下它是概率性的**。ζ = 0.2、ω = 60 时过零附近的速度
约 1400 pt/s，120Hz 一帧走 11.8pt，落进 ±0.05 的窗口只有约 0.4% 的机会——
所以它会表现为「偶尔一次回弹特别短」，而不是稳定复现的 bug。

实测（细采样 dt = 1e-5，让过零一定被采到）：

```
   自有判据（位置 + 速度）    过零 10 次，首次过零后仍有 12.6pt 摆幅
   仅位置（= completed）      过零  0 次，首次过零后摆幅 0        ← 当场死亡
```

所以静止判据自己定，两个量都要看，并且 `SpringInterpolation` 的 `threshold`
配成 0、`stopWhenHitTarget` 配成 false，把这个决定完全收回来：

```
   isAtRest  ⟺  |S| ≤ 0.05pt  且  |velocity| ≤ 0.5pt/s
```

对应的测试不能写成「逐帧断言 not at rest」——那条在 120Hz 下靠运气通过，
注入错误也发现不了（试过，全绿）。要断言的是**过零穿越的次数**。

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
    public var maximumStretch: CGFloat = 20      // setter 校验，见 §2.2
    public var resistanceFactor: CGFloat = 120
    public var angularFrequency: Double = 20     // 实测拟合，见 §2.5.1
    public var dampingRatio: Double = 0.75

    private var spring = SpringInterpolation(...)
    private var anchorY: CGFloat = 0

    public var maximumDisplacement: CGFloat { maximumStretch }
    public var wantsNextFrame: Bool { !isAtRest }               // 不是 completed，见 §3.4

    public mutating func willUpdate(_ context: ListAnimatorContext) {
        spring.setCurrent(spring.value + context.scrollDelta, spring.context.currentVel)
        spring.setTarget(0)
        spring.update(withDeltaTime: context.deltaTime)
        if abs(spring.value) > maximumStretch {                 // 写回状态，速度归零
            spring.setCurrent(spring.value.sign * maximumStretch, 0)
        }
        if isAtRest { spring.setCurrent(0, 0) }                 // 静止时零残留
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
    public static let subtle = Self(maximumStretch: 8, resistanceFactor: 240, angularFrequency: 26, dampingRatio: 0.9)
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

  1  feat: 弹簧纯模型   ✅ 已落地              不 import UIKit/AppKit 的 struct
     标量弹簧 + 单边权重 + 参数校验            18 条 property test，全部经故障注入
     钳制写回状态、自有静止判据                 验证过（注入错误必须有测试失败）：
     此时还是 internal，不承诺任何形状          · 任意初态都收敛到 0，且落到精确 0
                                              · |d| ≤ maximumStretch
                                              · d(i) 对索引非降（§2.3 的不变量）
                                              · 任意行高（含 0 与 4000）都不重叠
                                              · 符号翻转时单帧 |Δd| ≤ maximumStretch
                                                （有界，不是连续 —— §2.3）
                                              · 内部状态不超过 maximumStretch
                                              · 高速过零不被误判为静止（§3.4）
                                              · 半衰期 ~65ms、回弹 <8%（ω = 20, ζ = 0.75，§2.5.1）
                                              · 稳态的帧率依赖被钉住（§2.5）
                                              · 非法参数（0/负/NaN）不破坏以上任何一条
                                              · dt 上钳到 1/30 后仍收敛

  2  feat: display link + 位移落地  ✅        写入点分类改成**按排除法**：UIKit 的拖拽/
     placedFrame 真值通道                      惯性根本不经过本包，能标注的只有我们
     applyRowAnimator 统一落地点               自己做的那几次平移，其余一律计入
                                              UIKit transform / AppKit frame 分流
                                              14 条测试，全部经故障注入验证。
                                              其中 4 条最初注入错误也不红，重写了：
                                              两条是空过、一条依赖 apply 的内部行为、
                                              一条断言的性质两种实现都成立
                                              —— 最后那条退掉了一处改动（见下）

  3  refactor: 抽出 ListRowAnimator  ✅        协议 / ListAnimatorContext 定型
     弹簧成为它的第一份实现                     第二份实现写在**测试里**而不是 Example：
                                              这样它会被真的跑到。视差 animator 与弹簧
                                              处处相反（无时间状态、从不要帧、两侧都位移），
                                              它能跑通才说明协议描述的是 animator 而不是
                                              这个弹簧
                                              rebase 被它逼成了 compensateScrollOffset
                                              的 override —— 原先分散在两个调用点

  4  feat: ListView.rowAnimator 公开  ✅       viewportRect / mountRect 拆分、
                                              Reduce Motion、复位契约、
                                              rowView(for:) 文档注释修正（§7.7）
                                              Example 参数面板与真机选参**未做**

  5  perf: 回归确认  ✅                        见 §8.1

 ────────────────────────────────────────────────────────────────────────────
  6  refactor: insert / delete 并入协议         §7.8，独立一次重构，本文不承诺
```

### 8.1 性能：找到一处真回归，剩下的测不出来

第一次跑基线读到 70.8ms，与 HEAD 的 96.9ms 一比像是 37% 回归。**那个读数是冷启动离群值**——
把只改文档、代码与基线完全相同的那个 commit 拿来跑，得到 90.0 / 91.2 / 90.3ms。
真实基线是 ~90ms。教训：单次读数在这台机器上不构成证据。

交替测 8 轮（两种顺序各 4 轮）之后，`1k scroll layouts` 上有一处稳定的 ~5% 回归，
按 commit 二分定位到第 2 步。原因是：

```
   recycleRow 里新加的 clearRowDisplacement 是 withoutListAnimation { ... }
   AppKit 上那是一个 NSAnimationContext.runAnimationGroup —— 每回收一行开一次
   setRowPresentationOffset 里确实有提前返回，但抑制的代价在它外面
   于是一个根本没装 animator 的列表，也在为每一行回收付这笔钱
```

加一句 `guard row.presentationOffset != 0` 之后回归消失（中位 100.3 → 94.8ms，
当轮基线 ~95ms）。

**剩下的 0–4% 无法归因。** 把 in-process 采样从 3 提到 21 之后仍能看到 ~4% 的差，
但逐项还原（去掉 presentedFrame、去掉每趟的 animator 开销、把 mountRect 换回
viewportRect）没有一项能把它降下来，而 control 自己在同一段时间里从 97.9 漂到 104.2ms。
**机器的热漂移比要测的效应大**，就此打住，不编造归因。

不变的是 3.0 公布过的那两个数：`20k offset writes` 和 `20k visible queries` 全程无变化。

关闭时「不做任何 animator 的工作」这一条改成用计数器断言（`animatorTickCount`、
`mountOverscan`、`rowAnimatorLink`），那是确定性的，不受机器状态影响。

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

### 8.2 录屏暴露的两处结构性缺陷（都已修，见 8.2.1 / 8.2.2）

参数标定的同一批录屏里，还有一段是 iOS 模拟器上跑本库 Example 的。逐帧跟踪
（模板匹配 + 索引列灰度质心两种独立量法，结果逐帧一致）之后有两条：

**一、每次手指按下，画面会来回抖 2–3 帧，幅度约 30pt。**

```
   按下后连续 7 帧，行的屏幕位置（pt，向下为正）
       0    8.8    1.0   32.1    9.8   16.6   26.4
   逐帧位移
          +8.8   −7.8  +31.1  −22.3   +6.8   +9.8
```

底下那条 ~8.5pt/帧 的平滑斜坡是手指，叠在上面的 ±18pt 振荡不是。两次按下
（第 15 帧与第 45 帧）各出现一次，稳态拖拽段完全没有。

成因是**同一个视觉量由两个时钟写**：`contentOffset` 由 UIScrollView 每帧写，
`presentationOffset` 由 `RowAnimatorDisplayLink` 另一条 link 写。两者相减才是
行的落点，而它们不保证落在同一帧里——link 还是在 `layoutContent()` 末尾按需创建的，
建立那帧根本不会回调。渲染误差正好等于**一帧内 S 的变化量**：稳态时 ΔS ≈ 0
（所以拖拽段是干净的），起手时 S 从 0 冲到 30pt（所以抖在起手）。

要修就得让位移和它要抵消的那个 offset 在同一趟里算完：布局趟里推进弹簧
（`layoutSubviews` 与 offset 改写同一个 runloop turn、同一个 CA 事务），
display link 只负责松手之后的自由松弛。

**二、锚点会滑出内容，于是整屏一起滞后、一点层次都没有。**

同一段录屏里，四行之间的**相对**位移全程 ≤ 8pt，而整体滞后到了几十 pt——
即效果完全退化成「整块内容跟不上手指」，这正是「卡」的来源，因为直接操作被打断了。

原因是 `restingEdge` 取的是视口边缘，而那次手势里列表停在顶部并向下过卷，
视口上沿跑到了内容之上：

```
   视口 [−77, 343]   行中心 39 / 117 / 195 / 273   R = 120
   |c − a| = 116 / 194 / 272 / 350   →   w = 0.97 / 1 / 1 / 1     全部饱和
```

`min(1, |c−a|/R)` 的斜坡段整个落在了内容之外。内容填满视口的长列表里很少碰到，
**短列表、以及任何列表滚到两端时都是常态**。§5 挂起的「锚点选型」欠的就是这个，
不是手感取向问题。

两条的修法与量法见 8.2.2（第一条）与 8.2.1（第二条）；8.2.3 是顺带查出来的
第三条，8.2.4 记的是一条看着像缺陷、实际不是的东西。


### 8.2.1 锚点滑出内容：真机录屏把它量成了一条直线（已修；整个锚点方案后被 8.4 取代）

第四段录屏是 **iPhone 17 Pro Max 真机**（1320×2868，60fps 录屏、120Hz 屏），
同一个 Example，四行内容，连做三次「顶部下拉—松手—回弹」。逐帧量法：取每行的
索引标签与正文两条暗带，按暗像素质心定位，得到 8 条轨迹；四条标签轨迹的**均值**
是共模位移，**相邻差**减去静止帧的基线就是行间的相对张开量。

结论比模拟器那次干净得多，因为它是**可判定**的：

```
   相对张开量（gap0，单位 px，1pt = 3px）对共模位移的最小二乘直线
     第 1 次手势   斜率 −0.1792   残差 rms 0.17 px
     第 2 次手势   斜率 −0.1797   残差 rms 0.19 px
     第 3 次手势   斜率 −0.1802   残差 rms 0.17 px
```

三次独立手势、时长与速度都不同，却给出同一条直线，残差不到五分之一像素。
**弹簧的任何解都不是位移的一次函数**——它是时间的函数。是直线就说明这段位移
不是弹簧生成的，是几何生成的。斜率也对得上：`d(gap)/d(offset) = −S/R`，
S = 20、R = 120 时为 −0.167，实测 −0.179（差值落在行中心估计的误差里）。

发生了什么：回弹全程弹簧都顶在 20pt 的上限（回弹速度约 600pt/s，远超
`2ζv/ω = 20` 对应的 267pt/s），**动的不是弹簧，是锚点**。过卷时视口上沿在内容
之上，四行全部饱和、整块刚性平移；随着橡皮筋收回，上沿滑回内容里，第一行先
脱离饱和，于是它以与 offset 严格成正比的速度从后面三行组成的刚性块里「剥」出来，
到底再被弹簧收回去。用户说的「尤其是放手以后」就是这一段。

顺带解释了拖拽期间为什么**一点效果都没有**：下拉时 stretch 为负、锚点取视口下沿
（956pt），而内容只有 372pt 高，四行全部 |c−a| > R，仍然是刚性平移。

修法是把锚点夹到**可见内容**的边上，而不是视口的边上：

```swift
return direction >= 0
    ? max(viewport.minY, content.minY)
    : min(viewport.maxY, content.maxY)
```

为此 `ListAnimatorContext` 加了一个 `contentRect`。长列表里视口边缘本来就在内容
内部，夹取不生效，行为不变；过卷和短列表里锚点被钉在第一行/最后一行上，
整段过卷期间不动——权重就只随弹簧变，不再随 offset 变。

**没有拿它换一个更难看的东西**：把录屏里的 offset 轨迹重采样到设备真正跑的
120Hz，再分别用新旧两条规则驱动模型，单帧相对位移的最大跳变是

```
   旧规则 7.0pt（那一帧内容本身走了 10.1pt）
   新规则 10.0pt（那一帧内容本身走了 16.6pt）
   内容位移 < 1pt 的安静帧上，两者都 ≤ 1.2pt
```

即新规则的跳变只出现在内容本身就在快速移动的帧上，安静帧不跳。
（先按 60fps 录屏的帧率算过一版，得到 12.2pt，那是录制帧率的产物不是设备的。）

守住它的两个测试都做过反向注入：把 `restingEdge` 还原成取视口边缘，
`overscrollDoesNotRegradeTheRows` 与 `aListShorterThanItsViewportStillSpreads`
一起红。


### 8.2.2 两个时钟：layout 负责行程，link 负责时钟（已修）

8.2 第一条说的是「同一个视觉量由两个时钟写」。把这句话收窄到可判定的形式，
它只在**一帧**上成立：

- link 一旦在跑，它的回调和 layout 都在同一个 run loop turn 里，
  两次写在同一个 CA 事务里提交给渲染服务，谁先谁后都不产生可见误差
  ——先 tick 后 layout，layout 用的是本帧的 stretch；先 layout 后 tick，
  tick 会在提交前把位移重写一遍。
- 唯一的洞是**手势的第一帧**：link 是在 `layoutContent()` 末尾按需创建的，
  而 display link 不会在被创建的那一帧回调。于是这一帧把行摆到了新的 offset 上，
  却按手势开始之前的 stretch（也就是 0）去位移；真值要到下一帧才到，
  还叠在下一帧自己的行程上。

在锚点修好之前这条无所谓——那时四行全部饱和，差一帧只是整块内容差一帧，
是共模的。锚点钉到内容上之后它变成十几 pt 的**相对**位移晚到一帧，
正是模拟器那段录屏在按下瞬间量到的 ~30pt 抖动。

**第一版的修法只覆盖了这一条，是不够的**（codex review 指出，已修正）。
按「link 存不存在」来决定要不要补帧，问的不是「这一帧的行程有没有被积分」。
上一次手势还没松弛完时 link 是活的，而一帧之内的顺序完全可以是
「link 先 tick（此时 offset 还没动，消费到 0）→ 触摸改 offset → layout」——
这时 layout 看见 link 活着就不补，照样落一个陈旧的位移。共用一个 run loop turn
救不了它：tick 不可能积分一个当时还没发生的位移。§8.2.2 早先写的
「谁先谁后都不产生可见误差」是错的，只在 link 已经消费过本帧行程时才成立。

**最终的分工是：layout 负责行程，link 负责时钟。**

```swift
private func integrateTravelThisPassIsAboutToLand() {
    guard scrollLedger.pending != 0 else { return }
    advanceRowAnimator(duration: rowAnimatorLink == nil ? Self.unmeasuredFrame : 0)
}
```

有行程就注入，位移和它对应的 offset 因此总是同一趟落地；时间留给 link，
因为只有它知道一帧有多长。`duration: 0` 时 `SpringInterpolation` 的系数退化成
恒等式，所以那是一次纯冲量——一帧仍然只被松弛一次，由拥有它的那次 tick。
没有 link 时（包括没有 window 的场景）这一趟顺带充当一帧的时钟，
用 1/120：还没有任何一帧被量过，取两种刷新率里短的那个，宁可欠松弛也不过松弛。

副作用：`prefersReducedMotion` 那条提前返回现在会顺手 `scrollLedger.reset`。
关掉动效期间没人消费账本，攒一整程的行程会在重新打开的那一帧一次性花掉。

反向注入：

```
   去掉补帧             theFrameAGestureStartsOnIsAlreadyDisplaced 红
                        （第一帧全部行 presentationOffset == 0）
   换回 link == nil     aFrameThatArrivesWhileTheLinkIsRunningIsAlsoIntegrated 红
   这个条件             （tick → 改 offset → layout，位移不动）
   去掉 pending 判断    oneFramePerTickAndNoTicksWithoutFrames 红
```

`oneFramePerTickAndNoTicksWithoutFrames` 的期望值从 10 改成 20：一帧两次推进，
一次是 layout 交行程（不带时间），一次是 tick 交时间（没有行程可交）。
不动的 layout 不是帧，一次都不推进。

`aStatelessAnimatorIsDrivenByLayoutAndNeverAsksForAFrame` 里
`willUpdateCount == 0` 也改成 1：带行程的 layout 就是一帧，
想要 delta 但不想要 link 的实现有权收到它——之前它一次都收不到。


### 8.2.3 上下文和行 frame 不在同一个坐标系（codex review 发现，已修）

列表内部有两个纵坐标系：engine 从 0 开始摆行（`rowLayout.frame(for:)`），
而 `rectForRow(at:)` 在交给视图之前加上 `topInset`——`placedFrame` 存的是后者。
`viewportRect` 是 `contentOffset.y - topInset`，属于前者。

于是 `ListScrollSpring.update` 里拿 `frame.midY`（后者）去减 `restingEdge`
算出来的锚点（前者），**差一个 `topInset`**。`topInset = 80`、首行高 92、R = 120
时，正确的 `|c − a|` 是 46（权重 0.383），实际算成 126（权重饱和到 1）——
恰好在带 header 的聊天式布局上把最该分级的第一行压成刚性。

这条在锚点改之前就存在（那时 `restingEdge` 取的也是 `viewportRect` 的边），
只是那时全部饱和，看不出来。三个新测试全都用 `topInset = 0`，都漏了。

修法是在**构造 `ListAnimatorContext` 时**把两个矩形平移 `topInset`，
内部用的 `viewportRect` / `mountRect` 不动——补偿锚点、挂载、回收、测量覆盖
仍然在 engine 的坐标系里，它们本来就该在那儿。

`theContextAndTheRowFramesShareOneSpace` 拿 `context.contentRect.minY` 和
本趟 `update` 收到的最上面那个 `frame.minY` 直接比，不比 `topInset`——
实现能拿到的就这两样东西。反向注入（不平移）两条断言一起红。


### 8.2.4 弹簧全程顶在上限，不是缺陷（数值已随 8.4 更新为 15pt/800pt）

8.2.1 顺带暴露的一件事：回弹速度约 600pt/s，而 `2ζv/ω = maximumStretch`
在 ω = 20、ζ = 0.75 时对应 267pt/s——任何称得上滚动的速度都会把 stretch 顶到
20pt 的上限，于是「弹簧」在手势期间读起来像一个恒定偏移。

看着像缺陷，但它就是参照物的行为。Messages 那两段实测的相对张开峰值是
36.4px 和 29.2px（2.33 px/pt），即 15.6pt 和 12.5pt；当前参数下第一行相对后面
刚性块的张开量是 `20 × (1 − 46/120) = 12.3pt`，落在这个区间里。
`slowScrollingIsGradedAndAnythingBriskSaturates` 记的也是这件事：
录屏里每一次甩动，远场都是整块刚性移动，全部层次都集中在最靠近锚点的一两行。

所以不改。手势之间变化的是**上限被顶住多久**，不是顶到多高。


### 8.3 切片抽干在拖拽期间空转主线程（已修）

第三段录屏（同一个 Example，模拟器）里，拖拽期间内容位置是**成簇前进**的：
在两个同为 25ms 的采样间隔上，相邻两步是 +15.57pt 和 +0.81pt。平滑运动被不规则
采样是给不出这个的——画面里的内容确实在一顿一顿地走。

但这段录屏**没有**定位到原因：同一批帧里，模拟器画的触摸指示圈自己也在成簇移动
（+5.90 / +26.30 / +1.61 / +0.00 / −8.05 pt），也就是**输入本身**就是不均匀的。
鼠标合成触摸这条路上有多少抖动，视频分不出来。要分开只有一个办法：把
`rowAnimator` 置 nil 录一段对照，并且上真机而不是模拟器。

翻代码找它的时候翻出了另一件确凿的事，与这段录屏是否由它引起无关：

```swift
    if isUserInteractingWithScroll {
        scheduleSliceDrain()          // ← RunLoop.main.perform，下一轮 runloop 就跑
        return
    }
```

`scheduleSliceDrain()` 把下一趟挂在 **runloop 自己**身上，于是这个 block 以 runloop
能排干它的速度自我重排，主线程**一次都睡不着**。只要还有行没量过——也就是任何长到
值得做延迟测量的列表——它就在**整个拖拽期间**空转，UIKit 上还要加上拖拽之后
整段减速（`isUserInteractingWithScroll` 含 `isDecelerating`）。AppKit 的
`inLiveResize` 分支同一个写法。

实测：故障注入回原写法，0.2 秒里 `drainSlice` 跑了 **120,480 次**，即每秒约 60 万次
主线程唤醒。修好之后同一窗口 12 次。

改法是现成的：`scheduleSliceDrain(after:)` 本来就为宽度抖动那条分支存在，两处
「稍后再来」都改成按帧轮询。两种坏法都有测试盯着——空转（次数按速率断言，不按总数）
和干脆不再重排（松手后测量永不恢复）。

饿死主线程正是 `contentOffset` 成簇到达的成因之一，所以这条与录屏里看到的现象同类；
但它在那段录屏里**没有触发**（Example 初始只有 4 行，没有 pending 行）。修它是因为
它本身就是个缺陷，不是因为它解释了那段视频。


### 8.4 形状重写：锚点从内容边缘移到读者的手上（v2）

第五段真机录屏（9 行列表，先连加行再来回滚）把「不舒服」量成了两个可复现的形态，
且都不是参数问题，是形状问题：

1. **全程只有一个间隙在动。** 惯性减速段（f223–f233，约 180ms），第 5/6 行之间
   的间隙从 +2.7px 涨到 +12.0px，同屏其余 8 个间隙全程 |偏差| < 0.4px。快速段
   （f288–291，峰值 -86px/帧）里则**任何**间隙都不动——整屏刚性平移，效果不存在。
   成因是老形状自己的算术：`resistanceFactor = 120pt` 且锚点在内容边缘，于是
   整个过渡带只有 120pt 宽，通常恰好只装得下一条行界；带外权重全部饱和为 1，
   读同一个 stretch，相对位移为零。
2. **反向的一帧内塌缩。** f233 的 +12.0px 在 f235（触指落下、方向翻转的那一帧）
   直接变成 +1.4，下一帧 +0.1。这是符号门：`sign(centre − anchor) == sign(stretch)`
   在 stretch 过零的一瞬把所有行的读数同时归零。录屏里读起来就是「啪」。

对照 Messages 的逐元素追踪（f2 素材，194 帧，条带亚像素边缘）给出了参照物的真实形状，
三条都和老形状相反：

- **指针以下刚性。** 指针下方的两个气泡在整段素材（六次手势、两个方向）里
  相对间距恒为 66.0px，一帧都没动过。张开全部发生在指针**上方**。
- **梯度铺开、双向都有。** 指针上方的间隙偏差在 ±2–8px 之间、跨多个相邻对分布，
  **有正有负**——低于静止值的合拢在每次手势里都出现。「间隙只开不合」不是参照物的
  性质，是第一版单边门自己发明的。
- **反向平滑穿过零。** 方向翻转处间隙在 3–5 帧内穿过 0 重建反向形态，无跳变。

于是重写为：**锚点 = 读者的手（`ListAnimatorContext.interactionAnchorY`），
单边在其上方按距离分级，`resistanceFactor` 120 → 800（铺满一个视口），
删掉符号门，`maximumStretch` 20 → 15（Messages 两段实测峰值 12.5/15.6pt）。**
ω/ζ 不动（本来就是拟合值）。

考虑过并放弃的方案：每行独立弹簧（经典 WWDC 2013 dynamics 配方）。它额外买到的
只有过渡带内的空间振铃（Messages 追踪里确实可见：稳态剖面 0, 0, +5, +5, +1, −22
是带过冲的），代价是行复用/插入时的状态迁移、新挂载行的位相播种、以及 20 份
弹簧状态的账。共享标量在 R=800 下已经复现「每个可见间隙都分到一份张开量」，
振铃是唯一丢掉的东西，不值那个复杂度。

锚点的取得与冻结：UIKit 在 `isTracking` 时读 `panGestureRecognizer.location`，
AppKit 在 `scrollWheel(with:)` 里记事件位置（滚轮事件都带指针位置，含惯性段）。
存的是**视口相对** y（`rowAnimatorGripViewportY`），每帧换算回内容坐标——惯性期间
锚点钉在玻璃上的那个位置，而不是钉在飞驰而过的内容上。从未观测到交互时退到
视口底边，程序化滚动（如流式聊天的 `scrollToBottom`）因此天然获得「从最新一端
拽动」的读法。

一条契约随之改写：「行永不互相进入」降级为**有界互相接近**——相邻行至多靠近
`maximumStretch / resistanceFactor` 倍的间距（默认 <2%，肉眼不可见），换来反向
连续。权重分母取 `max(resistanceFactor, maximumStretch)`，任何参数组合下斜率
不超过 1:1，顺序永不交换。`displacedRowsStayInOrderAndOpenGaps` 与两个 property
test 按新界断言，反向塌缩由 `aReversalRidesThroughZeroInsteadOfSnapping` 盯着，
五项故障注入（复活符号门、去斜率下界、下方也分级、锚点回内容边缘等）全部被捕获。

#### 8.4.1 单边砍错了：手指两侧都要落后（v2.1）

v2 据 Messages 触控板追踪把「指针以下刚性」也搬了过来，真机一上手就被推翻。
产品规格（用户原话的转写）：1–6 行、手指拖着 4 往下滑，1-2-3 之间的间距张开、
5-6 向手朝里收拢，反向镜像，停下弹回等距，全程连贯。单边形状砍掉了「另一侧」，
于是某个方向的拖动只剩上方压缩、无处张开——读起来就是「整个屏幕在缩小，
放手才恢复」。

触控板追踪里那半边刚性大概率是指针**不动**且悬在气泡带下缘造成的观测窄化，
不是参照物的普遍性质。改法一行：权重取 `|anchor − centre|`，两侧同号落后——
被拖的行钉在手上，两侧内容绕着这只手流动。顺序界不变（斜率仍 ≤ 1:1，
现在对两个方向各成立一次）。

规格本身写成了测试 `gapsOpenBehindTheMotionAndCloseAheadOfIt`：六行、手在第 4 行、
两个方向各断言五个间隙的**符号**与随距离的单调性，再断言静止归零。故障注入
「恢复单边」与「下侧符号写反」各 6 处断言失败，被点名捕获。

#### 8.4.2 上手调出来的三样：波纹、幅度、松手即还（v2.2）

真机继续调，三条口头规格，全部进模型而不是进宿主代码：

1. **不均匀（"加一点随机"）。** 完全均匀的斜坡读起来像整张纸在剪切，Messages
   不是那样——气泡各有各的脾气。新旋钮 `unevenness`（默认 0.2）：在与握点的
   距离上叠一条双音正弦波（周期 0.9/0.55 个衰减距离，不可通约所以不重复），
   把每行的滞后往下压至多这个比例。**是波不是随机数**：对距离确定，同一行
   逐帧稳定（逐帧重掷会闪烁）；且光滑，其导数并进排序界——衰减距离下限
   `maximumStretch·(1 + unevenness·π(1/p₁+1/p₂)/2)/0.95` 随两个旋钮自动抬高，
   任何参数组合下位移映射斜率 ≤ 0.95，顺序永不交换。波只往下压、斜坡是天花板，
   所以 `maximumDisplacement` 契约不变。
2. **更大、更慢（"距离允许大一点""慢一点跟上进度"）。** `maximumStretch`
   15 → 24，ω 20 → 14：饱和速度从 ~340 降到 ~235pt/s，慢速滚动就能看到全幅
   拖尾；停下的半衰期 ~117ms（拟合曲线按 20/14 拉伸，特征值全部重钉）。
3. **引力只在手下（"一旦放手就 smooth animate 到 target pos"）。** 泵入按
   `isUserInteracting` 门控：UIKit 取 `isTracking || isDragging`（惯性段的
   `isDecelerating` 不算），AppKit 取触控板直接操纵段 + 滚动条拖拽
   （`isReaderHoldingScroll`，动量段不算）。松手瞬间停止喂行程，弹簧对着 0
   平滑还清，惯性只是刚性滚动；程序化滚动因此也不再触发效果。context 的
   `isUserInteracting` 语义随之收紧并写进文档。

三项各配注入：丢波纹（远场方差断言）、惯性继续喂（松手衰减断言）、松手瞬间
清零（一帧后仍余 ≥80% 的断言——这就是当初符号门的 pop，不允许换个入口回来），
全部被点名捕获。

#### 8.4.3 回波与浓度：第六段录屏之后（v2.3）

第六段真机录屏先排掉了两个假信号（裁剪区混入工具栏图标 → 顶部「+23px 冻结间隙」；
底部被切半的组 + home indicator → 同类）；逐对基线（按质量签名区分行对，不同文本
的质心在行内位置本来就差 ±5px）校正后，**静止残差归零**——实现没有 bug。剩下的
是两条口头规格：

1. **"太不明显了 弄多一点"。** 张开量确实只有每间隙 ~2pt（5-8px @3x）。
   `maximumStretch` 24 → 32、`resistanceFactor` 800 → 450：饱和时每间隙 ~6.6pt，
   张开集中在手周围四五行——第一版铺满整个视口的梯度，读出来就是什么都没发生。
2. **"放手之后前排的消息回来应该还有一点 delay"。** 场是一个标量、整体回位，
   表达不了"手边先到、远处晚到"。新旋钮 `returnDelay`（默认 0.12s）：每行经一个
   一阶跟随器看场，时间常数随与手的距离线性增长到 `returnDelay`。手边的行贴着场走，
   远行晚一拍——去程有波次，回程（眼睛真正盯着的那段）从手边荡出去。
   纯模型 API（`displacement(forRowCenteredAt:)`）保持瞬时场不动，跟随器只活在
   协议适配层（`followedDisplacement`），按 index 存在共享的 `Flow` 引用里：
   新挂载的行**按场播种**（不从零起跳）；`wantsNextFrame` 增加「任一跟随器未归位」
   分支——默认延迟下场先静、跟随器只剩亚像素，无所谓；`returnDelay` 拉到 0.5s 时
   场静止后远行还有约 1.6pt 在路上，链路只看场就会把它们冻在半空。

注入四发：去掉跟随（74 处断言失败）、播种为零、链路只看场（0.5s 延迟下冻结）、
以及沿用的旧注入，全部被点名捕获。Equatable 随之改为按旋钮比较——弹簧瞬态和
跟随器是显示状态，不是两个配置的区别。

#### 8.4.4 平滑要做在导数上（v2.4）

上手反馈的原话：跟手「非常两段」——第一段被拉出来，第二段突然一下跟过来，
动量在方向上不连续；「应该是速度上面要做平滑」。诊断出两处速度不连续，都对：

1. **泵入是位置注入 + 硬钳。** 拖动时 stretch 以 1:1 吃进手指位移（行在屏幕上
   钉着不动、间隙张开），顶到 32pt 硬钳的那一帧，行的速度从 0 瞬间跳到手指全速。
   改成**增益随占用度平方衰减**：`gain = 1 − (|S|/max)²`，同向泵入越接近饱和
   越吃不进，行从静止**平滑加速**进入跟随，饱和变成渐近线（600pt/s 稳态 24.8、
   2400pt/s 30.0，永远差一口气才到 32）；反向增益恢复 1——从饱和往回拽必须立即咬合。
   硬钳保留但只作为保险，正常动力学永远碰不到它。
2. **跟随器是一阶的。** 目标一跳，速度同帧反向。升级为**临界阻尼二阶**
   （闭式积分，带速度状态）：无论场怎么跳，行的运动保持 C¹——猛拽反向的那一帧，
   跟随器仍按原方向惯性走完至少一帧再掉头。

两条规格逐字成测试：`theRowAcceleratesIntoFollowingInsteadOfSnapping`
（恒速拖动全程逐帧步进的最大突变 < delta/4；硬钳的拐角实测 3–5，柔性 ~1.2）、
`aFollowerKeepsItsMomentumThroughAYank`（-60pt 猛拽帧跟随器不同帧反向）。
注入「恢复硬泵」（7 处断言失败）与「恢复一阶跟随」各自被点名捕获。

#### 8.4.5 接合也要有包络（v2.5）

修完饱和端还剩接合端：手一搭上滚动中的列表，泵入首帧就全增益咬合，
拖尾行在一帧内甩掉几乎全部滚动速度——**效果的开始本身就是一次顿挫**。
原话规格："让它 vector 保持的情况下，慢慢开始添加。"

新旋钮 `attack`（默认 0.12s）：一个一阶包络 `engagement ∈ [0,1]`，手在时升向 1、
手离开时落回 0，泵入按它缩放。搭手首帧只吃进约 6.7% 的行程（行几乎保持原速度
向量），弹簧的份额在 attack 时间内渐强混入；松手同速淡出，快速重抓从半途接起、
不从悬崖重来。包络是时间的一阶函数，所以行速度全程 C⁰、拐点不存在。

规格测试 `theEffectFadesInInsteadOfEngaging`：首帧咬合 < 行程的 10%、
咬合渐强（峰值 > 首帧 3 倍）、松手 6 帧后包络在中途（0.2–0.9）。
注入「绕过包络」3 处断言失败，点名捕获。

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
| ~~效果本身可能已经不存在于当代 Messages.app~~ | **已证实存在**：录屏逐帧可见每行以各自的速度移动，速度剖面在行边界上是分段常数（§2.5.1） |

## 10. 结局：场模型退役，换成 BouncyLayout 的 1:1 移植

§2–§3 的共享标量场连调七版（3.2.1 → 3.4.3：对称化、格里普锚点、软泵、
二阶跟随、attack 包络），用户的最终裁决仍是「还是不像」。两条独立的研究
线索给出了一致的解释：

- 这个效果的血统是 Apple 自己的 UIDynamics 配方（WWDC 2013 #217 /
  objc.io），**每个 cell 一根弹簧**钉在布局槽位上，不存在共享的场；
  Telegram-iOS 的 ListView 根本没有这个效果（它的弹簧只用于插入过渡）。
- 场模型为了补「场是一体的」这个先天缺陷，先后叠了 attack、returnDelay、
  follower 三层滞后——糊的来源恰恰是这三层滞后叠在一根场弹簧上。

于是按用户指示，把 roberthein/BouncyLayout（MIT，即上述配方的最流行封装）
**逐条对应**移植到 `ListRowAnimator` 上，即 `ListBouncyAnimator`：

| 原版 | 移植 |
| --- | --- |
| `UIAttachmentBehavior(damping, frequency)` | 每行一份 Box2D 软约束步进（`SoftConstraint`），ζ = damping，ω = 2πf——UIDynamics 内部就是 Box2D，这不是替身而是同一套算式 |
| `prepare()` 给进入缓冲视口的 cell 挂弹簧 | `update` 首次见到某行时在其槽位挂上，位移为零 |
| cell 离开视口摘弹簧 | 一段时间未被 offer 的 attachment 被剪除 |
| `shouldInvalidateLayout(forBoundsChange:)` 泵入 | `willUpdate` 的 `scrollDelta`（补偿已剔除） |
| `resistance = abs(touch − anchor) / 1000`，`min/max` 封顶 | 原样 |
| `floor(item.center)` | 泵入结果取 floor |
| `VIEWPORT_BUFFER = 200` | `maximumDisplacement = 200`（挂载外扩） |
| 三档 `BounceStyle`（0.8/2、0.7/1.5、0.5/1） | 数值原样 |
| cell 尺寸变化时全部拆掉重挂（会闪一帧） | 槽位移动就地重锚，保留位移——同一修复，没有那一帧闪 |

有意保留的原版语义，哪怕它与场模型的结论相反：

- **泵不看手**。原版对每次 bounds change 一视同仁——拖拽、惯性、回弹——
  阻力从手最后出现的位置量起（`panGestureRecognizer.location` 在抬手后
  返回的就是这个），`interactionAnchorY` 的语义恰好一致。场模型「重力只在
  手下存在」的门控是它自己的发明，测试 `momentumKeepsPumping` 把这条钉死，
  防止哪次清理把门控又带回来。
- **不保证行序**。独立弹簧在运动前方聚拢、后方拉开（正是用户描述的
  123/56 六行规格），原版本来就允许 cell 重叠；DEBUG 重叠断言只查
  placement，不查位移。§2.3 的非重叠证明随场模型一起退役。

与原版的全部差异就两处，都写在 `ListBouncyAnimator.swift` 的注释里：
重锚代替拆重挂（上表最后一行），以及静止吸附到精确槽位而不是
`floor(anchor)`（原版停在向下取整的锚点上，差距亚像素，而列表的回收
契约要求位移严格归零）。

场模型（`ListScrollSpring`）与其 991 行模型测试一并删除；管线
（协议、ledger、display link、mount overscan、rebase、placedFrame）
原封不动——本文档 §3–§7 描述的仍然是现行架构。

### 10.1 求解器与依赖

移植初版把弹簧交给 `SpringInterpolation` 库（闭式阻尼振子）。按用户指示
换成了 BouncyLayout 里面真正跑的那一个：`UIDynamicAnimator` 是 Box2D 的
封装，`UIAttachmentBehavior` 的 damping/frequency 就是 Box2D 软约束
（soft distance joint）的 dampingRatio/frequencyHz。`SoftConstraint.step`
按质量约掉后的一维形式逐式复刻（半隐式，γ/β 软化，见源码注释），
`ListBouncyAnimator` 与程序化滚动（`SoftSpring2D`，原参数 ζ=1、
ω=6/16 不变）共用这一份算式。`SpringInterpolation` 依赖随之从
Package.swift 移除；§1–§8 中对它的引用是场模型时期的历史记录，不再描述
现状。
