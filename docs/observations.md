# 观察、缓存查询与引用

`observe` 采集截图与 AX，宿主生成紧凑文本和会话内引用；`inspect` 读取同一份缓存快照。动作与引用校验见 [动作契约](actions.md)。

standard 接入 [AXP 观察](standard-ax.md)，复用本页的缓存、精简输出及查询。其元素引用仅用于 inspect，动作仍使用原有截图坐标与文本流程。AX 不可用时返回截图及失败原因。

standard 允许返回锁屏画面和全黑画面；锁屏、背光关闭或亮度变化本身不会使观察失败。截图仍须能解码，尺寸、方向、显示身份和屏幕点坐标映射须一致。系统服务无法提供截图时明确报告采集失败。输入前继续独立验证原观察的目标与当前画面，不因观察成功就自动放行输入。

两种模式统一返回 `observationAcquisition`：共同的观察 ID 只绑定本次证据，不表示原子快照。standard 独立 observe 用 `parallel_ax_screenshot` 并行请求 AX 和一张 PNG，记录主机 Unix 时钟的两路请求起止时间；standard 普通点击选定最终截图后读一次 AX，标记为 `selected_frame_then_ax`；Runner 维持 `runner_serial`，使用设备时钟返回的 AX 起止时间和截图结束时间，未知的截图开始时间为 null。时间区间包含请求与处理开销，不是设备实际采样时刻，不应跨时钟域相减。agent 同时读取 AX 与截图：AX 提供文字、结构和已知状态，截图补充布局、遮挡和自绘内容；只有影响目标判断的实质冲突才需要重新观察，普通动画不自动使 AX 失效。standard 的 AX 失败仍返回本次截图；截图失败则取消并回收 AX 工作，不发布残缺观察。动作前校验保持独立。


## 当前调用

```sh
iphone-use --session "$SESSION" observe
iphone-use --session "$SESSION" inspect o2:e9
iphone-use --session "$SESSION" inspect o2 --query Calendar
iphone-use --session "$SESSION" inspect o2:e9 --query scroll_view
iphone-use --session "$SESSION" inspect o2
iphone-use --session "$SESSION" inspect o2 --offset 20
```

`observe` 成功时直接输出多行文本及 PNG 路径；agent 需要用本地读图能力打开 PNG。`inspect` 成功时输出缓存上下文及按需展开的节点属性。失败仍为单行 JSON，退出码为 1。本地 IPC 保留 JSON 结构，CLI 不把逐节点 JSON 作为默认观察输出。

## 搜索缓存中的目标

`inspect oN --query TEXT` 先搜索该观察的全部已采集节点，再按每页最多 20 个匹配项输出；传元素引用时仅搜索该节点及其已采集子树。查询对原始 label、identifier、value 和 role 做不区分大小写的子串匹配，包含 observe 展示折叠掉的属性。每个来源节点最多匹配一次；同名父子节点和同名控件仍是不同结果，不自动合并或选出唯一目标。

匹配行带有完整 `ref`、`role`、屏幕点 `frame` 和 `parentRef`，并保留源类型、enabled、名称和值。名称、identifier 和值完整返回，不按字符数截短；异常超大页采用下述完整文件和缓存分段机制。匹配不意味着元素可见、可点击或仍可操作。

输出头部的 `matched_nodes` 是全部匹配数，`searched_nodes` 是搜索范围内已采集节点数。`--offset` 在查询模式下是**匹配列表**的偏移；继续使用返回的 `more: inspect ... --query ... --offset ...`，该命令保留原始查询。IPC result 同时返回实际采用的 `query`，CLI 核对它；旧宿主若忽略了参数，返回 `inspect_query_unsupported`，需用新 CLI 重新 connect 后 observe，不需要因此重建兼容的 Runner。

- `outputDeferred=true`：异常超大文本未内联，完整内容在 `fullText` 文件中，可按 `nextRead` 从同一缓存分段读取。
- `no_matches_in_capture=true`：搜索范围的已缓存数据中没有匹配，不证明界面上没有该目标。
- `source_missing=true`：源采集不完整，查询或 inspect 都无法补取缺失部分；`ax=unavailable` 同样不能支持目标不存在的结论。

查询成功（包括零匹配）沿用 inspect 的续期规则，不请求 Runner、不新增观察 ID、不改变引用资格，也不修改磁盘快照。缓存淘汰后不能继续查询。query 须为 1–256 UTF-8 字节，拒绝控制字符和纯空白，非法值返回 `invalid_inspect_query`；越界偏移返回 `invalid_offset`。未提供 `--query` 时保留原有详细属性和节点分页。

调用方已知引用时应直接 `inspect oN:eN`，不要从整棵树逐页查几何信息；尚未找到目标时用查询。`inspect oN | rg TEXT` 仅搜索那一页输出。若截图已明确显示目标位置，可通过已有的受守卫约束坐标动作继续；不必为找到一个 AX 名称而反复读取无关页。

[CLI 输出样例](examples/observe/observe.cli.example.txt) 由 Calculator 观察整理而来，路径、ID 与时间戳均已脱敏替换，不附原始截图。下方仅展示格式，示例引用不能用于当前设备：

```text
[e16] scroll_view "Last Expression"
  [e18] text "‎2‎+‎3"
[e19] scroll_view "Edit field"
  [e22] text "‎5"
[e23] key "Delete"
[e24] key "All Clear"
```

显示为 `[e24]` 的节点，其完整引用是该会话的 `o4:e24`。引用只标识已采集的来源节点，不能据此认定设备目标唯一、可点击或仍在原位置。`refs=current` 只表示它尚未被宿主失效；type/press 执行前校验实时 AX 目标，tap/swipe 执行前校验上下文和分区画面。画面相似不延长引用，见 [动作前画面校验](screen-guard.md)。

## 输出与缓存限制

这些是可调整的工程默认值，沿用已确认的产品语义，不代表用户逐项指定了数值。

- 默认观察先按当前呈现层级和视口精简，不再按 60 行截取树的前缀。Runner 单次采集开启系统模态视图过滤，观察与动作前校验使用同一规则；完整保存系统返回的节点，不额外采集被模态排除的背景树。宿主按屏幕与窗口、滚动容器的交集省略视口外节点，并尊重来源明确返回的 `visible=false`。这些宿主展示过滤掉的已采集节点仍可 inspect，系统未返回的节点不能通过 inspect 补取。
- `presentation=viewport` 标明这是展示投影；`hierarchy=modal_filtered` 表示来源明确采用模态过滤，旧 Runner 或未知来源标记 `hierarchy=unknown`，不根据焦点、同名控件或兄弟顺序猜遮挡。`omitted_nodes` 是宿主展示过滤数量，不是源采集缺失。模态过滤和边界仍不能描述所有透明覆盖、自绘内容或像素遮挡，最终可见内容以截图为准。
- 默认观察完整返回精简后的内容，不再按 8 KiB 或单属性 160 字符截断。仅保留 128 KiB 编码响应保护预算（为宿主响应信封预留 4 KiB），超出后交付完整文本文件和缓存读取入口，不删除节点或属性；该预算不作为可见性的判据。
- 省略无内容、无状态、无 identifier 的普通容器，折叠重复 WebView 包裹与可确认重复的普通容器表示。保留控件、文字、原始 `ax_value`、禁用状态、命名分组；同名控件不合并，有 identifier 时显示以便区分。
- 精简正文省略未知状态，不逐行或在每次响应头部重复 `enabled=unknown` / `keyboard_focus=unknown`。缺失属性表示未知，不表示 true、false 或可操作；该约定写在 CLI `observe --help` 和 agent 工具说明中。已知 enabled 输出 `enabled=true` / `disabled`，已知焦点输出 `keyboard_focus=true/false`。
- 对 `unknown` 角色，仅折叠可识别的原生布局包装节点：无文字、值、提示、标识和已知 enabled/焦点，只有一个直接子节点、两者边界一致，且没有独有 traits、未识别属性或未遍历子节点。保留未知类、空叶节点、列表单元格、分支分组和带状态节点。折叠只改变展示缩进（最近保留祖先），不改缓存的原始父子关系、引用或动作身份。
- 视口内、enabled、模态层级成员或名字都不证明控件可点击，不把输入框的 AX value 猜成“已输入内容”。边界未知时保留未知节点；输入前的实时身份、焦点与画面校验保持独立。
- standard 的候选可见性策略默认展示已查询的语义候选和键盘区域，再应用公共视口投影；未查询的结构节点保留在缓存，不据此断言不可见。原生键盘普通字符键仅在默认展示中省略，原始结构、属性和 visible 仍保留在同一缓存，可通过 inspect 查询；功能键及未知类型不按字符键删除。候选范围外未查询的 visible 保持未知，独立补充的组合节点不猜造父级。详见 [standard AX](standard-ax.md#full-structure-candidate-visibility-and-keyboard-presentation)。
- 每个原始节点均有观察内引用，包含默认文本折叠掉的节点；`inspect oN` 可读取它们。引用分配和表示规则都在宿主，Runner 没有观察 ID、短引用或缓存策略。
- 只缓存最近两次成功观察。新观察不会修改旧快照；第三次成功观察删除最早的 PNG 和 JSON。有效会话结束或空闲到期时删除观察缓存，诊断文件保持原有清理策略。
- `inspect` 每页最多 20 个节点，`--offset` 是所选已采集子树内的节点偏移，下一页命令随输出返回。取消单节点 4 KiB 替换提示与查询属性截短；超大页和单个超长属性采用与 observe 相同的完整文本交付机制。
- 异常超大输出明确标记 `outputDeferred`，不会冒充 AX 采集失败。当前 Runner 导出 XCTest 返回的完整树，不再固定截断为 200 节点；传输或时间超限明确失败。`source_truncated` / `source_missing` 保留用于描述采集不完整的快照，inspect 只能读取已采集数据，不能补取 App 未暴露的节点。采集与精简展示分开，详见[完整 AX 采集](architecture.md#runner-路径定位与完整-ax-采集)。
- PNG 与保留全部已导出节点属性的 snapshot.json 写入会话目录，文件 0600、目录 0700。JSON 不是完整 XCTest dictionaryRepresentation；缓存文件也不独立证明引用当前有效。

## 引用与生命周期

所有操作在宿主工作队列串行执行。`open` 和通过本地引用解析的设备动作调用后端前先标记当前引用为 pending；正常完成或结果 unknown 后失效。明确未发送且没有其他失效原因的错误恢复此前仍有效的引用，参数检查失败不改变引用；发现目标变化时仍须失效。unknown 不重发。

开始一次新观察会使旧引用失效，即使新采集失败也要求重新 observe；成功后仅最新观察拥有 current 引用。旧快照只要仍在缓存就可 inspect，但不会恢复操作资格。已淘汰的快照返回 `observation_unavailable`；未采集的节点返回 `node_not_captured`；旧 session 无法再 inspect。当前动作已使用这些状态，并从原快照构造设备校验所需的目标描述。

成功的 observe / inspect 完成后续期，失败的 inspect 不续期，status 保持不续期。已接收的操作和关闭仍沿用原有串行化与空闲规则。

## 采集事实与限制

薄 Runner 检查 SpringBoard 是否有唯一 Alert；否则采集已经 open 且确认 runningForeground 的目标 App；前台不能确认时返回截图，AX 标记 unavailable、foreground 标记 null。App 内唯一 Alert 使用独立的 `appAlert` 范围。唯一系统 Alert 的结构属于 SpringBoard，不能把目标 App 当成该系统界面的前台身份。没有独立发现任意前台 App 的能力，也没有自动选择允许/拒绝权限的动作。

AX 开始/结束时间与截图后的时间分别返回；屏幕点坐标框来自采集 App 的 frame，未知时返回 null，PNG 像素尺寸由 Mac 解码图像验证。截图与 AX **不是原子快照，也不保证界面已稳定**。

App 切换动画可能造成截图与 AX 表现不一致，调用 agent 应读取截图并按需重新 observe。通用 App 打开与安装检查见 [设备/App 发现](discovery.md)，签名与协议升级见 [首次接入](onboarding.md)。

### 异常超大文本

`fullText` 指向当前观察缓存内的完整 UTF-8 文本文件，权限 0600；其中包含呈现正文、来源说明和 inspect 页的节点续页命令，不包含可能过期的 `refs=current` 首行。返回的 `outputID` 属于该观察。按返回命令读取，例如：

```sh
iphone-use --session "$SESSION" inspect o2 --output t1 --byte-offset 0
```

该操作只读缓存，不重采集、不恢复动作引用。结果携带当前 `refs`、`content`、`byteOffset`、`bytesReturned`、`totalBytes`、`outputComplete`；未读完时有 `nextByteOffset` 和 `nextRead`。按顺序拼接 **content 字段**可恢复完整文件，不拼接带说明的 text 字段。分段只在 UTF-8 Unicode scalar 边界断开；组合字符和 emoji 序列可能跨段，但拼接后逐字节不变。越界或字符内部偏移明确报错；文件尾部残缺 UTF-8 同样报错，未完成的成功分段必须推进字节偏移。U+FEFF 即使位于分段开头也作为正文保留。`--output` 只接受观察引用，不能同时使用元素引用、`--query` 或非零节点 `--offset`；`--byte-offset` 与节点偏移不同。

每个观察最多保留最近4份不同的超大文本输出；重复结果仅在文件内容逐字节匹配时复用。损坏或丢失的文件会从同一观察缓存重建并分配新 outputID，旧输出 ID 失效，不恢复动作引用；淘汰时文件已不存在视为已清理，其他文件系统错误仍明确失败。后续超大查询可能淘汰较早输出，输出被淘汰后返回 `output_unavailable`，仍可 inspect 同一观察的原始缓存。观察淘汰或会话清理同时删除其文本文件。需要长期保存时使用 `--evidence-dir`，归档会复制完整文本。分段延续 inspect 的空闲续期规则，但不更新引用资格；旧 CLI/宿主未确认 outputID 时明确拒绝兼容性降级。

完整文本写入失败时返回 `outputError` 和原始 snapshot 路径，不伪装成已返回完整文本、不改写 AX 状态；可再次 inspect 已缓存观察重试输出，无需重复手机输入。正常文件和分段读取不会产生新观察 ID。
