--[[
脚本名称：秒杀下单原子校验脚本（seckill.lua）

一、脚本功能
该脚本用于在 Redis 中原子化完成“秒杀下单前置校验 + 状态写入”，保证高并发场景下：
1) 不会超卖（库存不足时直接拒绝）
2) 同一用户只能下单一次（防止重复下单）
3) 校验与扣减在一次 Lua 执行内完成，避免并发竞争导致的数据不一致

二、输入参数（ARGV）
ARGV[1] = voucherId  优惠券/秒杀券 ID
ARGV[2] = userId     用户 ID
ARGV[3] = orderId    订单 ID（当前脚本内未使用，通常用于后续异步落库或消息链路）

三、Redis Key 设计
1) 库存 Key：seckill:stock:{voucherId}
   - 类型：String
   - 含义：该券当前可用库存（整数）
2) 订单用户集合 Key：seckill:order:{voucherId}
   - 类型：Set
   - 含义：已成功下单的用户 ID 集合，用于“一人一单”判重

四、执行流程
1) 读取库存（GET stockKey）：
   - 若库存 <= 0，立即返回 1（库存不足）
2) 校验是否重复下单（SISMEMBER orderKey userId）：
   - 若用户已在集合中，立即返回 2（重复下单）
3) 扣减库存（INCRBY stockKey -1）
4) 记录下单用户（SADD orderKey userId）
5) 返回 0（下单资格校验通过，且 Redis 侧状态更新成功）

五、返回码约定
0 = 成功
1 = 库存不足
2 = 重复下单

六、并发与一致性说明
Redis 会将 Lua 脚本作为单条命令串行执行，本脚本内所有读写操作具备原子性。
因此不会出现“先判断有库存，随后被并发请求抢空仍继续下单”的竞态问题。
]]
-- 1.参数列表
-- 1.1.优惠券id
local voucherId = ARGV[1]
-- 1.2.用户id
local userId = ARGV[2]
-- 1.3.订单id
local orderId = ARGV[3]

-- 2. 数据key
-- 2.1. 库存key
local stockKey = 'seckill:stock:' .. voucherId
-- 2.2. 订单key
local orderKey = 'seckill:order:' .. voucherId

-- 3. 脚本业务
-- 3.1. 判断库存是否充足 get stockKey
if(tonumber(redis.call('get', stockKey)) <= 0) then
    -- 3.2. 库存不足，返回1
    return 1
end

-- 3.2. 判断用户是否下单 SISMEMBER orderKey userId
if(redis.call('sismember', orderKey, userId) == 1) then
    -- 3.3. 存在，说明是重复下单，返回2
    return 2
end

-- 3.4. 扣库存 incrby stockKey -1
redis.call('incrby', stockKey, -1)
-- 3.5. 下单（保存用户） sadd orderKey userId
redis.call('sadd', orderKey, userId)
-- 3.6.发送消息到队列中， XADD stream.orders * k1 v1 k2 v2 ...
redis.call('xadd', 'stream.orders', '*', 'userId', userId, 'voucherId', voucherId, 'id', orderId)
return 0