--[[
  Slurm job_submit.lua 脚本 (shpu 倾情打造)
  功能：
  1. 禁止用户使用 --nodelist 或 --exclude。
  2. 尽量避免用户自己手动指定 CPU 和内存等信息。
--]]

-- 辅助函数，用于从 TRES (Trackable Resources) 字符串中解析 gres/gpu 的数量
-- TRES 字符串示例: "gres/gpu:2", "cpu=8,mem=16G,gres/gpu:kepler:1"
local function parse_gpus_from_tres(tres_string)
    if not tres_string or tres_string == "" then
        return 0
    end
    local count_str = tostring(tres_string):match("gres/gpu:[a-zA-Z]*:?([0-9]+)")
    if count_str then
        return tonumber(count_str)
    end
    count_str = tostring(tres_string):match("gres/gpu=[a-zA-Z]*:?([0-9]+)")
    if count_str then
        return tonumber(count_str)
    end
    return 0
end

function init()
    slurm.log_info("job_submit/lua loaded.")
    return slurm.SUCCESS
end

function slurm_job_submit(job_desc, part_list, submit_uid)
    -- ===================================================================
    -- 规则 1: 禁止指定节点以及排除节点
    -- ===================================================================
    if (job_desc.req_nodes and job_desc.req_nodes ~= "") or (job_desc.nodes and job_desc.nodes ~= "") then
        local user_message = "错误：不允许使用 --nodelist 或 -w 参数指定节点。请移除该参数后重试"
        slurm.log_user(user_message)
        slurm.log_info("refused user " .. tostring(submit_uid) .. "'s job, because he/she has used --nodelist or -w")
        return slurm.ERROR
    end

    if (job_desc.exc_nodes and job_desc.exc_nodes ~= "") then
        local user_message = "错误：不允许使用 --exclude 参数排除节点。请移除该参数后重试"
        slurm.log_user(user_message)
        slurm.log_info("refused user " .. tostring(submit_uid) .. "'s job, because he/she has used --exclude")
        return slurm.ERROR
    end


    -- ===================================================================
    -- 规则 2: CPU 以及内存策略
    -- ===================================================================
    local num_gpus = 0

    -- 检查 --gpus 快捷方式对应的专用字段
    if job_desc.num_gpus and job_desc.num_gpus > 0 then
        num_gpus = job_desc.num_gpus
    else
        -- 解析 --gres 通用方式对应的 TRES 字符串
        local tres_sources = {
            job_desc.tres_per_job,
            job_desc.tres_per_node,
            job_desc.tres_per_task,
            job_desc.tres_per_socket
        }
        for _, tres_string in ipairs(tres_sources) do
            num_gpus = parse_gpus_from_tres(tres_string)
            if num_gpus > 0 then
                break
            end
        end
    end

    -- 作用没有请求 GPU 时，必须指定 CPU 数量
    if num_gpus == 0 then
        if not (job_desc.tres_per_task and string.find(job_desc.tres_per_task, "cpu", 1, true)) then
            user_message = "错误：未申请 GPU，则必须使用 --cpus-per-task 参数指定 CPU 数量。请添加该参数后重试"
            slurm.log_user(user_message)
            return slurm.ERROR
        end
        job_desc.min_mem_per_cpu = "1024" --每个 CPU 分配 1G 内存
    end

    -- 作业请求了 GPU 时，由系统分配CPU和内存
    if num_gpus > 0 then
        -- 定义一个包含所有冲突参数及其错误信息的表
        local forbidden_params = {
            { field = job_desc.cpus_per_tres,                                                         flag = "--cpus-per-gpu" },
            { field = job_desc.tres_per_task and string.find(job_desc.tres_per_task, "cpu", 1, true),  flag = "--cpus-per-task" },
            { field = job_desc.mem_per_tres,                                                          flag = "--mem-per-gpu" },
            { field = job_desc.min_mem_per_node,                                                      flag = "--mem" },
            { field = job_desc.min_mem_per_cpu,                                                       flag = "--mem-per-cpu" }
        }

        -- 循环检查是否存在任何冲突参数
        for _, param in ipairs(forbidden_params) do
            if param.field and param.field ~= 0 and param.field ~= "" then
                local user_message = string.format("错误：指定 GPU 后不允许使用 %s 参数指定资源。系统将自动分配，请移除该参数。", param.flag)
                slurm.log_user(user_message)
                slurm.log_info("refused job: user specified " .. param.flag .. " with a GPU request.")
                return slurm.ERROR
            end
        end

        -- 如果没有冲突，则自动分配资源
        job_desc.cpus_per_tres = "gres/gpu:8"    -- 每个 GPU 分配 8 个 CPU
        job_desc.mem_per_tres = "gres/gpu:32768" -- 每个 GPU 分配 32G 内存
    end

    return slurm.SUCCESS
end

function slurm_job_modify(job_desc, job_rec, part_list, modify_uid)
    return slurm.SUCCESS
end

function fini()
    slurm.log_info("job_submit/lua unloaded.")
    return slurm.SUCCESS
end
