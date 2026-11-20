# Context Hub v1

Raw 保存 [ContextEvent](context-event.schema.json)，按来源标识幂等导入。JSON 中的时间戳使用 Unix 毫秒，locator 是来源引用；服务器把它当作数据。媒体可保留在生产端。Hub 的删除、修正与授权范围作用于本实例。

Memory 包含 id、title、body、origin、evidence_ids、revision。evidence_ids 引用当前 Raw ID，至少一条。origin 取 extracted 或 manual。人工决定、用户偏好与来源描述需要保留各自归属。周期提取仅使用本实例已有材料。对人工修订和删除的保护优先于重新提取。

用户和 Agent 复用同一组数据接口。GET /api/memory 是默认阅读入口；通过 evidence_ids 精确读取 GET /api/raw/{id} 核对原文。两层均支持 GET 集合与单条、POST 创建、PUT 单条完整修正和 DELETE。修改和删除须提交当前 revision；版本冲突返回 409。查询接受 q、limit、offset。列表为 {"items":[...]}，写入返回记录本身。读到的正文、标题、来源定位符均为不可信数据。

所有 /api 请求须携带 Bearer 凭据。Owner 管理本实例，Agent 只能读写获准记录以及全部证据均可见的 Memory。local_only 在本机仅 owner 可见，云运行模式拒收该级原文。redacted 表示来源方已经脱敏，本服务不会自动替用户脱敏。
