local unpack = require 'busted.compatibility'.unpack
local shuffle = require 'busted.utils'.shuffle

local function sort(elements)
  table.sort(elements, function(t1, t2)
    if t1.name and t2.name then
      return t1.name < t2.name
    end
    return t2.name ~= nil
  end)
  return elements
end

local function remove(descriptors, element)
  for _, descriptor in ipairs(descriptors) do
    element.env[descriptor] = function(...)
      error("'" .. descriptor .. "' not supported inside current context block", 2)
    end
  end
end

local function init(busted)
  local function exec(descriptor, element)
    if not element.env then element.env = {} end

    remove({ 'randomize' }, element)
    remove({ 'pending' }, element)
    remove({ 'describe', 'context', 'it', 'spec', 'test' }, element)
    remove({ 'setup', 'teardown', 'before_each', 'after_each' }, element)

    local parent = busted.context.parent(element)
    setmetatable(element.env, {
      __newindex = function(self, key, value)
        if not parent.env then parent.env = {} end
        parent.env[key] = value
      end
    })

    local ret = { busted.safe(descriptor, element.run, element) }
    return unpack(ret)
  end

  local function execAll(descriptor, current, propagate)
    local parent = busted.context.parent(current)

    if propagate and parent then
      local success, ancestor = execAll(descriptor, parent, propagate)
      if not success then
        return success, ancestor
      end
    end

    local list = current[descriptor] or {}

    local success = true
    for _, v in pairs(list) do
      if not exec(descriptor, v):success() then
        success = nil
      end
    end
    return success, current
  end

  local function dexecAll(descriptor, current, propagate)
    local parent = busted.context.parent(current)
    local list = current[descriptor] or {}

    local success = true
    for _, v in pairs(list) do
      if not exec(descriptor, v):success() then
        success = nil
      end
    end

    if propagate and parent then
      if not dexecAll(descriptor, parent, propagate) then
        success = nil
      end
    end
    return success
  end

  local file = function(file)
    busted.publish({ 'file', 'start' }, file.name)

    busted.wrapEnv(file.run)
    if not file.env then file.env = {} end

    local randomize = busted.randomize
    file.env.randomize = function() randomize = true end

    if busted.safe('file', file.run, file):success() then
      if randomize then
        file.randomseed = busted.randomseed
        shuffle(busted.context.children(file), busted.randomseed)
      elseif busted.sort then
        sort(busted.context.children(file))
      end
      if execAll('setup', file) then
        busted.execute(file)
      end
      dexecAll('teardown', file)
    end

    busted.publish({ 'file', 'end' }, file.name)
  end

  local describe = function(describe)
    local parent = busted.context.parent(describe)

    busted.publish({ 'describe', 'start' }, describe, parent)

    if not describe.env then describe.env = {} end

    local randomize = busted.randomize
    describe.env.randomize = function() randomize = true end

    if busted.safe('describe', describe.run, describe):success() then
      if randomize then
        describe.randomseed = busted.randomseed
        shuffle(busted.context.children(describe), busted.randomseed)
      elseif busted.sort then
        sort(busted.context.children(describe))
      end
      if execAll('setup', describe) then
        busted.execute(describe)
      end
      dexecAll('teardown', describe)
    end

    busted.publish({ 'describe', 'end' }, describe, parent)
  end

  local it = function(element)
    local finally

    busted.publish({ 'test', 'start' }, element, parent)

    if not element.env then element.env = {} end

    remove({ 'randomize' }, element)
    remove({ 'describe', 'context', 'it', 'spec', 'test' }, element)
    remove({ 'setup', 'teardown', 'before_each', 'after_each' }, element)
    element.env.finally = function(fn) finally = fn end
    element.env.pending = function(msg) busted.pending(msg) end

    local status = busted.status('success')
    local updateErrorStatus = function(descriptor)
      if element.message then element.message = element.message .. '\n' end
      element.message = (element.message or '') .. 'Error in ' .. descriptor
      status:update('error')
    end

    local parent = busted.context.parent(element)
    local pass, ancestor = execAll('before_each', parent, true)

    if pass then
      status:update(busted.safe('element', element.run, element))
    else
      updateErrorStatus('before_each')
    end

    if not element.env.done then
      remove({ 'pending' }, element)
      if finally then status:update(busted.safe('finally', finally, element)) end
      if not dexecAll('after_each', ancestor, true) then
        updateErrorStatus('after_each')
      end

      busted.publish({ 'test', 'end' }, element, parent, tostring(status))
    end
  end

  local pending = function(element)
    local parent = busted.context.parent(pending)
    busted.publish({ 'test', 'start' }, element, parent)
    busted.publish({ 'test', 'end' }, element, parent, 'pending')
  end

  busted.register('file', file)

  busted.register('describe', describe)

  busted.register('it', it)

  busted.register('pending', pending)

  busted.register('setup')
  busted.register('teardown')
  busted.register('before_each')
  busted.register('after_each')

  busted.alias('context', 'describe')
  busted.alias('spec', 'it')
  busted.alias('test', 'it')

  assert = require 'luassert'
  spy    = require 'luassert.spy'
  mock   = require 'luassert.mock'
  stub   = require 'luassert.stub'

  busted.replaceErrorWithFail(assert)
  busted.replaceErrorWithFail(assert.True)

  return busted
end

return setmetatable({}, {
  __call = function(self, busted)
    init(busted)

    return setmetatable(self, {
      __index = function(self, descriptor)
        return busted.executors[descriptor]
      end,

      __newindex = function(self, key, value)
        error('Attempt to modify busted')
      end
    })
  end
})
