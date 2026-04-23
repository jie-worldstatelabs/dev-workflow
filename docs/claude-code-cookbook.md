# 用 stagent 驯服 Claude Code

一本 cookbook：列举 Claude Code 常见的"不听话"场景、直接用 prompt 讲为什么不够用、以及用 `stagent` 插件把规矩写成状态机的做法。

## 为什么 prompt 管不住

直接跟 Claude Code 说「先调研再写代码」「改完必须跑测试」在短任务里有效，但：

- **上下文稀释**：session 一长，早期指令被挤到窗口尽头，CC 渐渐失忆。
- **判据模糊**：「调研够了没」「测试跑通没」靠 CC 自己说，它经常自我放行。
- **跨 session 消失**：新开一个 session，规矩得重讲一遍。
- **没审计痕迹**：它说做了就算做了，事后没有 artifact 可以回溯。

`stagent` 把这些规矩写成 `workflow.json` 状态机：每个阶段有输入依赖、产出 artifact、pass/fail 判据。偏离了状态机会把它拉回来；到了 `max_epoch` 强制 `escalated`，不会无限打转。

## 用法总览

安装插件（在 Claude Code 里）：

```
/plugin marketplace add jie-worldstatelabs/stagent
/plugin install stagent
```

两个核心命令：

```
# 交互式创建 workflow，会问你要哪些 stage、依赖、判据
/stagent:create "<自然语言描述>"

# 用创建好的 workflow 跑一个任务
/stagent:start --flow=cloud://<你>/<名字> "<任务>"
```

创建完的 workflow 默认发到 hub（<https://stagent.worldstatelabs.com/hub>），跨 session、跨机器都能复用。浏览器里能看 stage timeline + 实时 diff + artifact。

---

## 场景库

### 场景 1 · 不调研就瞎写

**症状**：让 CC 加一个 feature，它不 grep 现有实现、不查官方文档，直接开写。结果 API 版本对不上、项目里已有的工具类重造了一遍、风格跟现有代码割裂。

**直接 prompt 为什么不够**：
```
"先看看现有代码再写"
"先查 context7 / 官方文档确认 API"
```
前 3 轮还记得，到第 10 轮决策时又回到凭记忆写。更致命的是，CC 判断「看够了没」用的是"我好像懂了"，而不是"我列了证据"。

**写成 workflow**：
```
/stagent:create "研究优先工作流。
- research：grep 项目里相关实现、读相关模块、查 context7 / 官方文档，
  产出 research.md 必须包含：可复用代码清单（带文件:行号）、API 版本、类似实现参考。
- plan：根据 research.md 写 plan.md，计划里每个设计决策必须引用 research.md 的条目编号。
- execute：按 plan 实现。
- verify：跑测试，FAIL 回 execute。"
```
发布后跑：
```
/stagent:start --flow=cloud://you/research-first "给 API 加限流"
```

### 场景 2 · 改完自己说 done

**症状**：CC 写完代码不跑 build、不跑测试、不看 lint，直接说「已完成」。下一轮你一运行发现 TypeError。

**直接 prompt 为什么不够**：「改完跑一下测试」是祈使句，没有状态机挡着。CC 觉得「看起来没问题」就跳过验证。

**写成 workflow**：
```
/stagent:create "execute → build → test → review 四段式。
- execute：写代码。
- build：跑 npm run build / cargo build / go build；exit != 0 回 execute 循环，stdout/stderr 存成 artifact。
- test：跑测试；FAIL 回 execute；PASS 进 review。
- review：subagent 对着 baseline commit 做对抗式 code review，列风险点；FAIL 回 execute。"
```

### 场景 3 · 单点修改 scope creep

**症状**：让它修 bug A，它顺手 refactor B、重命名 C、还给 D 加了个 helper。PR 变 unreviewable，回滚也一锅端。

**直接 prompt 为什么不够**：「只改必要的」太主观。CC 写到一半觉得「这里顺手改了更干净」——从它的视角这是负责任，从你的视角是 scope 爆炸。

**写成 workflow**：
```
/stagent:create "最小改动工作流。
- plan：产出 plan.md 必须列出 files[] 数组（预计要改的文件）和 estimated_loc（总行数估计）。
- execute：按 plan 改。
- scope-check：diff 出来的文件集合必须是 plan.files 的子集；超出的文件数 > 0 或 diff 行数 > 2×estimated_loc，FAIL 回 plan 重新规划（而不是 execute，强迫它先承认 scope 变了）。"
```

### 场景 4 · 修 bug 只修症状

**症状**：报错 CC 就加 `try/except: pass`；断言挂了把断言改松；测试 flaky 就加 retry。根因从来没查清过。

**直接 prompt 为什么不够**：「找根因不要加 try/catch」——CC 觉得自己已经"分析过了"，`except` 是「稳健」。

**写成 workflow**：
```
/stagent:create "根因分析工作流。
- reproduce：产出最小复现脚本 + 期望行为 vs 实际行为表。
- hypothesize：至少列 3 个可能原因，每个打分（likely / possible / unlikely）。
- verify：用 log / 断点 / 二分法排除 hypothesis，产出 verify.md 必须引用具体证据（日志行、commit、函数名）。
- fix：fix.md 必须引用 verify.md 里确认的根因；禁止 try/except 吞异常。"
```

### 场景 5 · TDD 说了不听

**症状**：你说「test first」，CC 回答「好的」，然后直接写 implementation，测试放 TODO。

**写成 workflow**：
```
/stagent:create "TDD 严格模式。
- red：写一个失败的测试，必须 run 一遍并把 stderr 里的 FAIL 行贴进 artifact；没看到 FAIL 就不准进 green。
- green：最少改动让测试过；artifact 要贴 PASS 输出。
- refactor：跑整个测试套件保证还绿；FAIL 回 green。"
```

### 场景 6 · UI 改完不看浏览器

**症状**：改完 UI 只看代码就说完成，视觉 regression 全靠你自己打开浏览器发现。

**写成 workflow**：
```
/stagent:create "UI 改动工作流。
- execute：改代码。
- qa：用 playwright MCP 启动 dev server、打开改动涉及的页面、截图存 artifact；
  跑 WCAG 对比度检查（CLAUDE.md 要 4.5:1）；
  mobile viewport 也截一张；
  任一 FAIL 回 execute。"
```

### 场景 7 · 长任务中途忘约束

**症状**：session 开头说「不要加 emoji 装饰」「测试覆盖率要 80%」，到半程开始飘。

**写成 workflow**：让约束进 stage 的 prompt 里，每个 stage 重新加载——CC 进到那个 stage 时指令是"新鲜的"。
```
/stagent:create "... 每个 stage 的 instructions 里都显式列：
不要加 emoji 装饰、测试覆盖率 ≥ 80%、commit message 用 conventional。"
```

---

## Workflow vs 直接 prompt

| | 直接 prompt | workflow |
|---|---|---|
| 规矩保留 | 上下文稀释 | 每个 stage 重新加载 |
| 判据 | CC 自己说算 | 状态机 pass/fail |
| 跨 session | 要重说 | hub 发一次永久复用 |
| Artifact 审计 | 无 | 每个 stage 归档 |
| 循环保护 | 无 | `max_epoch` 到了强制 escalated |
| 可视化 | 聊天记录 | 浏览器 timeline + diff + artifact |

## 进阶

- **改已有 workflow**：`/stagent:create --flow=cloud://you/name "在 qa 后加一个 deploy-dry-run 阶段"` —— 同一个命令既是创建也是编辑。
- **逛别人的 workflow**：<https://stagent.worldstatelabs.com/hub>。
- **中途介入**：`/stagent:interrupt` 暂停，`/stagent:continue` 恢复（支持跨机器，需要 git push 同步代码）。
- **本地模式**：加 `--mode=local` 全离线，state 存在 `<project>/.stagent/`。
