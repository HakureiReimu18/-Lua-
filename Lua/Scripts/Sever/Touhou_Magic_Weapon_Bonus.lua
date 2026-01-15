local MAGIC_SKILL = "Touhou_Magic"
-- 魔法能力的上限：超过该值不会再提高伤害加成
local MAX_MAGIC_SKILL = 300
-- 非线性曲线强度：数值越大，前后段增幅越明显，中段越平缓
local CURVE_WOBBLE = 0.15
-- 调试开关：为 true 时输出无法解析攻击者的原因
local DEBUG_LOG = false

local WEAPON_LEVELS = {
    {
        tag = "Touhou_Weapon_Level05",
        max_bonus = 0.2,
    },
    {
        tag = "Touhou_Weapon_Level04",
        max_bonus = 0.15,
    },
    {
        tag = "Touhou_Weapon_Level03",
        max_bonus = 0.1,
    },
    {
        tag = "Touhou_Weapon_Level02",
        max_bonus = 0.1,
    },
    {
        tag = "Touhou_Weapon_Level01",
        max_bonus = 0.1,
    },
}

local function clamp(value, min_value, max_value)
    if value < min_value then
        return min_value
    end
    if value > max_value then
        return max_value
    end
    return value
end

local function get_skill_curve_factor(skill)
    -- 非线性曲线：前期增长较快、中期变缓、后期再次加速
    -- 以 0~1 的标准化技能值 t 为输入，输出同样落在 0~1 的倍率
    local t = clamp(skill / MAX_MAGIC_SKILL, 0, 1)
    local curved = t + CURVE_WOBBLE * math.sin(2 * math.pi * t)
    return clamp(curved, 0, 1)
end

local function get_hand_items(character)
    -- 获取双手物品：用于判断是否满足“双手都为魔法武器”的条件
    if character == nil or character.Inventory == nil then
        return nil, nil
    end

    local right_hand = character.Inventory.GetItemAt(InvSlotType.RightHand)
    local left_hand = character.Inventory.GetItemAt(InvSlotType.LeftHand)
    return right_hand, left_hand
end

local function get_weapon_level_config(item)
    -- 根据武器的等级标签选择对应配置
    if item == nil then
        return nil
    end

    for _, config in ipairs(WEAPON_LEVELS) do
        if item.HasTag(config.tag) then
            return config
        end
    end

    return nil
end

local function resolve_magic_weapon_config(character)
    -- 规则：
    -- 1) 双手必须都是“魔法武器”；或
    -- 2) 双手拿着同一把魔法武器（双手武器通常会占用左右手同一物品实例）。
    -- 不满足上述条件，则不给加成。
    local right_hand, left_hand = get_hand_items(character)
    if right_hand == nil or left_hand == nil then
        return nil
    end

    -- 如果左右手是同一把武器，且它是魔法武器，则允许加成
    if right_hand == left_hand then
        return get_weapon_level_config(right_hand)
    end

    -- 如果左右手是不同的武器，则两把都必须是魔法武器
    local right_config = get_weapon_level_config(right_hand)
    local left_config = get_weapon_level_config(left_hand)
    if right_config == nil or left_config == nil then
        return nil
    end

    -- 当双持不同等级的魔法武器时，取较低档的配置作为加成基准，避免穿插高低档造成过高收益
    if right_config.max_bonus <= left_config.max_bonus then
        return right_config
    end

    return left_config
end

local function safe_get_attack_result_field(attackResult, field_name)
    -- 某些版本的 Lua 绑定不会暴露 AttackResult.Attacker，直接访问会抛错
    -- 用 pcall 保护字段读取，避免脚本报错导致全局 Hook 中断
    local ok, value = pcall(function()
        return attackResult[field_name]
    end)
    if not ok then
        return nil
    end
    return value
end

local function resolve_attacker_from_source(source)
    -- 尝试从不同类型的对象中解析出 Character
    if source == nil then
        return nil
    end

    if source.Character ~= nil then
        return source.Character
    end

    if source.Inventory ~= nil and source.Inventory.Owner ~= nil then
        return source.Inventory.Owner
    end

    return source
end

local function get_attacker_character(attackResult)
    -- 尝试读取不同版本可能暴露的字段，优先使用 Attacker
    if attackResult == nil then
        return nil
    end

    local attacker = safe_get_attack_result_field(attackResult, "Attacker")
    if attacker == nil then
        attacker = safe_get_attack_result_field(attackResult, "AttackerEntity")
    end
    if attacker == nil then
        attacker = safe_get_attack_result_field(attackResult, "Source")
    end
    if attacker ~= nil then
        return resolve_attacker_from_source(attacker)
    end

    -- 进一步尝试通过 Attack 对象获取攻击者
    local attack = safe_get_attack_result_field(attackResult, "Attack")
    if attack ~= nil then
        local attack_attacker = safe_get_attack_result_field(attack, "Attacker")
        if attack_attacker == nil then
            attack_attacker = safe_get_attack_result_field(attack, "AttackerEntity")
        end
        if attack_attacker == nil then
            attack_attacker = safe_get_attack_result_field(attack, "Source")
        end
        if attack_attacker ~= nil then
            return resolve_attacker_from_source(attack_attacker)
        end
    end

    if DEBUG_LOG then
        print("Touhou.MagicWeaponBonus: attacker is nil, skip bonus.")
    end

    return nil
end

local function scale_attack_result(attackResult, bonus)
    -- 直接修改本次攻击的 affliction 强度，实现即时伤害加成
    if attackResult == nil or attackResult.Afflictions == nil then
        return
    end

    local multiplier = 1 + bonus
    for affliction in attackResult.Afflictions do
        if affliction.Strength ~= nil then
            affliction.Strength = affliction.Strength * multiplier
        end
    end
end

Hook.Add("character.applyDamage", "Touhou.MagicWeaponBonus", function(characterHealth, attackResult, hitLimb)
    -- 命中结算时调整伤害：无需依赖 Affliction 持续时间
    if characterHealth == nil or attackResult == nil or hitLimb == nil then
        return
    end

    local attacker_character = get_attacker_character(attackResult)
    if attacker_character == nil or attacker_character.IsDead or attacker_character.Removed then
        return
    end

    -- 限制魔法能力上限，避免无限成长
    local skill = attacker_character.GetSkillLevel(Identifier(MAGIC_SKILL)) or 0
    if skill <= 0 then
        return
    end

    skill = math.min(skill, MAX_MAGIC_SKILL)

    -- 必须满足双手都为魔法武器（或双手握持同一把魔法武器）
    local config = resolve_magic_weapon_config(attacker_character)
    if config == nil then
        return
    end

    -- 计算加成（使用非线性曲线，并限制最大值）
    local curve_factor = get_skill_curve_factor(skill)
    local bonus = config.max_bonus * curve_factor
    if bonus <= 0 then
        return
    end

    scale_attack_result(attackResult, bonus)
end)