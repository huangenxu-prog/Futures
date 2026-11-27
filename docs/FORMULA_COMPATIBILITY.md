# 期汇指标公式兼容报告

基线为 main 的 `39d6b87`。编辑指标时选择公式来源，粘贴正文，选择主图或副图，检查后保存并启用。原平台把周期单独保存在参数表时，按其实际设置填写，例如 `SHORT=12 LONG=26 M=9`。正文与参数分别保存。历史记录缺少平台字段时使用原生规则。

### 函数对照

下表列出本次导入入口的白名单。仅描述技术指标子集。相同拼写也可能有不同的窗口或绘图约束。原生既有函数、命名颜色及旧公式求值路径继续使用。

| 类型 | 三个导入平台共有 | 通达信另外支持 | 同花顺期货通另外支持 | 文华财经另外支持 |
|---|---|---|---|---|
| 数学 | ABS、MAX、MIN | SQRT、POW、EXP、LN、LOG、SIGN、FLOOR、CEILING、INTPART、SIN、COS、TAN | SQRT、POW | SQRT、POW |
| 统计、趋势 | MA、EMA、SMA、HHV、LLV、SUM、COUNT | EXPMA、WMA、DMA、STD、STDP、VAR、VARP | — | HV、LV、EMA2、WMA、DMA、STD、STDP、VAR、VARP |
| 条件、状态 | IF、NOT、CROSS、REF、BARSLAST、FILTER、EXIST、EVERY、VALUEWHEN | IFN、IFF、BETWEEN、BARSCOUNT、BARSLASTCOUNT、BARSSINCE、HHVBARS、LLVBARS | RANGE、CROSSUP、CROSSDOWN | IFELSE、BETWEEN、CROSSUP、CROSSDOWN、BARSLASTCOUNT、BARSSINCE、ISUP、ISDOWN、ISEQUAL |
| 绘图 | DRAWTEXT、STICKLINE、命名输出线、正负柱 | STICKLINE 第四参数为宽度 | STICKLINE 第四参数为宽度 | STICKLINE 第四参数为颜色，STICK 可指定宽度和颜色，DRAWNUMBER 可标注数字 |

允许中文变量、隐藏赋值、匿名函数输出、花括号和双斜杠注释、比较与布尔运算。OHLCV 来自当前合约与周期。三个入口共享 Swift AST、求值器和图表适配器，平台差异在编译时解析。未列入平台函数表的调用在检查和保存时拒绝。

### 部分支持与边界

| 函数或语法 | 期汇行为 |
|---|---|
| STD、STDP、VAR、VARP | 通达信和文华分别使用样本/总体分母，样本窗口 1 缺值。原生 STD 保留总体分母。期货通四种函数暂拒绝。 |
| IFN、IFELSE | 通达信 IFN 条件成立返回第三参，原生 IFN 保留历史行为。期货通 IFN 暂拒绝。 |
| EMA、SMA | 文华预热使用可用根数，文华 EMA(4) 输入 6、7、8、9 最后一根为 8。其余入口以首个有效值为种子。无当期输入时递推重置。 |
| MA、HHV、LLV、SUM、COUNT、EVERY | 文华支持序列周期。MA 需满窗，HHV、LLV、SUM、COUNT 预热使用已有历史，周期 0 对后四者表示全部已有历史。通达信 SUM 支持固定周期含 0。其余窗口用法受原引擎限制，多数仅支持固定正整数。 |
| REF、极值、离散信号 | REF 接受非负整根偏移，历史不足时输出缺值。普通固定极值窗要求满窗，文华 HHVBARS、LLVBARS 暂拒绝。源客户端首根、缺行情、极值并列、跨会话结果未经全面对拍。 |
| STICKLINE、STICK | 通达信支持 0～4 宽及实心/实线空心；期货通支持宽 0～10、空心 0/1；文华 STICK 支持宽 0～3，3 映射到整根蜡烛宽。文华内联颜色支持命名色和常量 RGB。像素宽度由期汇柱宽计算，不能保证与桌面端完全一致。 |
| 样式 | 八种命名色，通达信和期货通六位 COLOR 色码按 BGR 转换，文华使用 RGB(R,G,B) 或命名颜色。LINETHICK1～5、STICK、COLORSTICK、NODRAW、文字 FONTSIZE6～40。柱状图使用可见输出。NODRAW 保留后续可引用的值。 |
| DRAWTEXT | 固定文本 1～32 字，条件为真且定位值有效时画在该根 K 线；字体与客户端有差别。 |
| 资源与数据 | 正文和编译参数合计 32 KiB、4,096 个词元、96 条语句、48 条可见输出、最多 20,000 根 K 线。固定窗口上限 500，动态历史受输入数据量约束。除零和无效数学定义域返回缺值。 |

**不支持** 外部平台图标库、DRAWLINE 回填或延伸、FILLRGN、DRAWGBK、通达信与期货通 DRAWNUMBER、点线样式、函数库调用、跨合约跨周期引用、财务/选股字段、交易指令、未来引用及重绘函数（例如 REFX、BACKSET、ZIG）。未复制平台客户端专有资源。

### 自动验证

* `scripts/FormulaEngineSelfTest.swift` 保留原生回归，并调用独立 Python 参考计算。26 组 × 80 根非单调 OHLCV，比较每条可见输出逐根数值与缺值位置。样本包含期货通 MACD、多空柱，文华布林叠加均线、KDJ、成交量、条件文字、状态示例，以及通达信函数示例和常见 BBI、BIAS、MTM、ROC、WR 算法。参数表按各测试输入给出。
* 同时检查历史 JSON、源码和参数往返、信号位置、柱起止和空实心、颜色、10 个明确拒绝的输入。工作流中原有策略回归继续运行。
* iOS Build 使用真实模拟器、固定离线行情，经现有 ChartDisplaySettings 和 TradingChart 渲染。检查主图均线和文字、副图直方图和条件柱的特征色及区域分离，截图为 chart-renderer-replay/formula-platforms.png。测试跑数与构建结论以 PR 同一提交的 Actions 日志为准。
* 测试包含手册示例、根据公开指标定义写出的公式，以及专门覆盖边界的夹具。独立数值参考不是三家终端导出的金标准；未取得终端逐根导出、所有版本颜色对照或用户真机签名验证。

### 公开原文批量检查

另从文华金融统计、逻辑判断和绘图三份手册提取 94 个去重的例题代码块，按原先的多句顺序送入文华入口。22 个产生绘图输出且通过 64/128 根历史前缀一致性检查，72 个明确拒绝。拒绝项包括只定义变量而无绘图输出、引用日期字段、交易命令、未来函数及未适配绘图。此处的通过数只代表这些样本可求值且对历史前缀一致，不用于估计平台整体兼容率。

[逐例结果](FORMULA_PUBLIC_RESULTS.txt) 记录文档摘要、样例摘要和错误。以下命令可重跑；第二个 Python 参数可指定已下载的三个原版 HTML 文件所在目录。

```sh
swiftc -O App/Models/FormulaEngine.swift App/Models/FormulaComposition.swift scripts/FormulaPublicSampleTest.swift -o /tmp/formula-public
python3 scripts/check-public-formula-samples.py /tmp/formula-public
```

### 参考资料

* [通达信官方函数表](https://help.tdx.com.cn/gspt/docs/markdown/redword/functionlist.html)、[公式编辑示例](https://help.tdx.com.cn/gspt/docs/markdown/tdxgs-1d1k7b2r1ihug/tdxgs-1d1okhe0atqoc.html)、[清华大学出版社教材的颜色说明](https://www.tup.tsinghua.edu.cn/upload/books/yz/102418-01.pdf)
* [期货通官方产品说明](https://download.10jqka.com.cn/free/futures)、[核新同花顺署名 PC 用户手册（期货公司托管）](https://www.guoshengqh.com/storage/file/20260108/50fae8d9cd2afb6c465601da536a0606.pdf)、[投教材料中的期货通 MACD 原编辑器与参数截图](https://www.investor.org.cn/xxzx/tjzl/tjnrgmjytx/bk/kj/jyxl_3400/202302/P020230226488127095465.pdf)、[期货通红面积的 COLOR0000FF 公开样本](https://www.bilibili.com/video/BV1Hz42187ut/)、[公开多空主图样例](https://licai.cofool.com/ask/qa_5717454_1_2.html)。未取得期货通完整公开的逐函数规范。
* [文华 WT8 指标示例](https://www.wenhua.com.cn/new_guide/Wh8/view6.html)、[金融统计](https://www.wenhua.com.cn/guide/wh8/view7_2.html)、[逻辑判断](https://www.wenhua.com.cn/guide/wh8/view7_4.html)、[绘图函数](https://www.wenhua.com.cn/guide/wh8/view7_6.html)、[文华署名麦语言 KDJ 示例](https://www.xinhu.cn/attachments/1309/06/e1c24e4e87d2efa.pdf)、[标准差资料补充](https://www.fxsola.com/whbc/whsolitongjihansu.asp)
* [常见指标的公共定义及参考实现列表](https://oss.dolphindb.cn/zh/modules/mytt/mytt.html)
