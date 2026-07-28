# Task 1 Fix Round 1 报告

状态：DONE

## 红灯证据

先新增 `forced=1,count=0` 回归测试并运行目标测试。测试在
`test_forced_chain_without_candidates_is_malformed` 断言失败：解析器发布了
`SelectChain`，而非规格要求的 `Malformed`。这确认测试覆盖了复审指出的真实
缺陷。

## 修复内容

- 解析器拒绝强制且无候选的连锁帧，避免发布无法发动、也不能跳过的待决策状态。
- 连锁发动索引改为仅接受 OCGCore `int32_t` 可表达的非负范围；
  `INT32_MAX` 可编码，`INT32_MAX + 1` 被拒绝。
- 将响应构造器头文件中的过期“三个函数”说明更新为不依赖数量的表述。

## 验证

```sh
cmake --build build/native --target test_duel_message_parser test_duel_response -j4
ctest --test-dir build/native -R '^(duel_message_parser|duel_response)$' --output-on-failure
git diff --check
```

结果：2/2 目标测试通过，差异空白检查无输出。

## 提交

`fix(规则): 收紧连锁响应边界`
