--[[
-- Factorio::Signal
--  signal :: SignalID: ID of the signal.
--  count :: int: Value of the signal.
--
-- Factorio::SignalID
--  type :: string: "item", "fluid", or "virtual".
--  name :: string (optional): Name of the item, fluid or virtual signal.
--]]

local config = require "config"

ltn_combinator = {
  entity = nil,
  ltn_stop_type = nil,
}

ltn_combinator.__index = ltn_combinator

function ltn_combinator:new(entity)
  if not entity or not entity.valid or entity.name ~= "ltn-combinator" then
    print("ltn_combinator:new: entity has to be a valid instance of 'ltn-combinator'")
    return nil
  end

  local obj = {}
  setmetatable(obj, self)

  obj.entity = entity
  obj:_parse_entity()

  return obj
end

-- ltn_combinator:_parse_entity
--  is called upon opening any ltn-combinator. Checks if ltn-signals are sorted to
--  their predefined slot, determines ltn stop type and validates signals
function ltn_combinator:_parse_entity()
  if not self.entity or not self.entity.valid then return end
  local control = self.entity.get_or_create_control_behavior()

  -- check if signals are sorted correctly
  local need_sorting = false
  for slot = 1, config.ltnc_item_slot_count do
    local signal = control.get_signal(slot)
    if signal.signal ~= nil then
      local type = signal.signal.type
      local name = signal.signal.name

      -- check if its a ltn signal and if its in a correct slot
      if type == "virtual" and config.ltn_signals[name] ~= nil then
        need_sorting = config.ltn_signals[name].slot ~= slot or need_sorting

        -- remove ltn signals in 1 .. 13 if it equals 0 or default value
        -- signals aren't emitted if 0, and if no signal is present LTN default is used
        if signal.count == config.ltn_signals[name].default then
          if name == "ltn-requester-threshold" or name == "ltn-provider-threshold" then
          elseif name == "ltn-network-id" and settings.global["ltnc-emit-default-network-id"].value then
          else
            control.set_signal(slot, nil)
          end
        elseif signal.count == 0 then
          control.set_signal(slot, nil)
        end
      end

      -- check if a non ltn signal is in slot 1..13
      if slot <= config.ltnc_ltn_slot_count and config.ltn_signals[name] == nil then
        need_sorting = true
      end
    end
  end

  if need_sorting == true then
    --dlog("ltnc::_parse_entity: combinator needs sorting of signals")
    self:_sort_signal_slots()
  end

  -- determine ltn stop type (requester, provider or depot)
  -- By default we will at least be a provider
  self.ltn_stop_type = config.LTN_STOP_PROVIDER

  -- The Depot signal makes LTN ignore all all ther signals.  If we're a depot, that's it.
  if control.get_signal(config.ltn_signals["ltn-depot"].slot).signal ~= nil then
    self.ltn_stop_type = config.LTN_STOP_DEPOT
  else
    -- requester -- If a requester threshold is set, add the requester flag
    if (settings.global["ltnc-high-provide-threshold"].value and
        control.get_signal(config.ltn_signals["ltn-provider-threshold"].slot).count == config.high_threshold_count) or
       (control.get_signal(config.ltn_signals["ltn-requester-threshold"].slot).signal ~= nil or
         control.get_signal(config.ltn_signals["ltn-requester-stack-threshold"].slot).signal ~= nil or
         control.get_signal(config.ltn_signals["ltn-requester-priority"].slot).signal ~= nil or
         control.get_signal(config.ltn_signals["ltn-disable-warnings"].slot).signal ~= nil) or
        (self:_has_requests()) then
      self.ltn_stop_type = bit32.bor(self.ltn_stop_type, config.LTN_STOP_REQUESTER)
    end

    -- provider - Remove the provider flag if the provide threshhold equals the high_provide_threshold and
    -- provider-stack-threshhold == 0
    if control.get_signal(config.ltn_signals["ltn-provider-threshold"].slot).signal ~= nil
       and control.get_signal(config.ltn_signals["ltn-provider-threshold"].slot).count == config.high_threshold_count then
      self.ltn_stop_type = bit32.band(self.ltn_stop_type, bit32.bnot(config.LTN_STOP_PROVIDER))
    end
  end

  -- validate ltn signals to match stop type
  self:_validate_signals()
end

-- ltn_combinator:_has_requests
-- returns true if there are item or fluid signals with negative values indicatind a request for materials
function ltn_combinator:_has_requests()
  if not self.entity or not self.entity.valid then return end
  local control = self.entity.get_or_create_control_behavior()
  for i = 1 + config.ltnc_ltn_slot_count, config.ltnc_item_slot_count do
    local signal = control.get_signal(i)
    if signal.signal ~= nil and (signal.signal.type == "item" or signal.signal.type == "fluid") and signal.count < 0 then
       return true
    end
  end
  return false
end

-- ltn_combinator:_sort_signal_slots
--  sort ltn signal to their predefined slot and move any non-ltn signals to slot 14 .. 27
function ltn_combinator:_sort_signal_slots()
  if not self.entity or not self.entity.valid then return end
  local control = self.entity.get_or_create_control_behavior()

  -- cache all signals
  local previous = {}
  for slot = 1, config.ltnc_item_slot_count do
    local signal = control.get_signal(slot)

    if signal ~= nil and signal.signal ~= nil then
      table.insert(previous, signal)
    end

    control.set_signal(slot, nil)
  end

  -- reassign all signals to a proper slot
  local misc_slot = config.ltnc_ltn_slot_count + 1
  for _, signal in pairs(previous) do
    local type = signal.signal.type
    local name = signal.signal.name

    -- check if its a ltn signal
    if type == "virtual" and config.ltn_signals[name] ~= nil then
      control.set_signal(config.ltn_signals[name].slot, signal)
    else
      control.set_signal(misc_slot, signal)
      misc_slot = misc_slot + 1
      if misc_slot > config.ltnc_item_slot_count then
        break
      end
    end
  end
end

-- ltn_combinator:_validate_signals
--  Validates LTN signals in regards to the stop type. Removes invalid signals
function ltn_combinator:_validate_signals()
  if not self.entity or not self.entity.valid then return end
  local control = self.entity.get_or_create_control_behavior()
  local signals = config.ltn_signals

  -- Stop DEPOT: Remove every signal but ltn-network-id, ltn-depot-priority, and ltn-depot
  if self.ltn_stop_type == config.LTN_STOP_DEPOT then
    for slot=1, config.ltnc_ltn_slot_count do
      local keep = slot == signals["ltn-depot"].slot or
                   slot == signals["ltn-depot-priority"].slot or
                   slot == signals["ltn-network-id"].slot
      if not keep then
        control.set_signal(slot, nil)
      end
    end

  -- Stop Requester
  elseif self.ltn_stop_type == config.LTN_STOP_REQUESTER then
    control.set_signal(signals["ltn-provider-stack-threshold"].slot, nil)
    control.set_signal(signals["ltn-provider-priority"].slot, nil)
    control.set_signal(signals["ltn-locked-slots"].slot, nil)
    control.set_signal(signals["ltn-depot"].slot, nil)
    control.set_signal(signals["ltn-depot-priority"].slot, nil)
  elseif self.ltn_stop_type == config.LTN_STOP_PROVIDER then
    control.set_signal(signals["ltn-requester-threshold"].slot, nil)
    control.set_signal(signals["ltn-requester-stack-threshold"].slot, nil)
    control.set_signal(signals["ltn-requester-priority"].slot, nil)
    control.set_signal(signals["ltn-disable-warnings"].slot, nil)
    control.set_signal(signals["ltn-depot"].slot, nil)
    control.set_signal(signals["ltn-depot-priority"].slot, nil)
  -- 6 = bit32.bor(REQUESTER, PROVIDER)
  elseif self.ltn_stop_type == bit32.bor(config.LTN_STOP_PROVIDER, config.LTN_STOP_REQUESTER) then
    control.set_signal(signals["ltn-depot"].slot, nil)
  elseif self.ltn_stop_type == config.LTN_STOP_NONE then
    control.set_signal(signals["ltn-depot"].slot, nil)
  end
end

-- ltn_combinator:set_stop_type
--  set stop type to Requester, Provider or Depot
function ltn_combinator:set_stop_type(stop_type)
  if not self.entity or not self.entity.valid then return end
  if stop_type < 0 or stop_type > 7 then return end

  dlog("new stop type set: " .. stop_type)
  if bit32.btest(stop_type, config.LTN_STOP_PROVIDER) then
    if settings.global["ltnc-high-provide-threshold"].value and self:get("ltn-provider-threshold") == config.high_threshold_count then
      self.entity.get_or_create_control_behavior().set_signal(9, nil)
    end
  elseif settings.global["ltnc-high-provide-threshold"].value then
    self:set("ltn-provider-threshold", config.high_threshold_count)
  end

  -- if new stop type is depot apply signal
  if stop_type == config.LTN_STOP_DEPOT then
    self:set("ltn-depot", 1)
  end

  self.ltn_stop_type = stop_type

  self:_validate_signals()
end

-- ltn_combinator:get_stop_type
function ltn_combinator:get_stop_type()
  if not self.entity or not self.entity.valid then return end
  return self.ltn_stop_type and self.ltn_stop_type or config.LTN_STOP_NONE
end

-- ltn_combinator:set_enabled
function ltn_combinator:set_enabled(enable)
  if not self.entity or not self.entity.valid then return end
  self.entity.get_or_create_control_behavior().enabled = enable
end

-- ltn_combinator:is_enabled
function ltn_combinator:is_enabled()
  if not self.entity or not self.entity.valid then return false end
  return self.entity.get_or_create_control_behavior().enabled
end

-- ltn_combinator:set
--  @param  signal_name as defined data
--  @param  integer value (32bit signed) for this signal
function ltn_combinator:set(signal_name, value)
  if not self.entity or not self.entity.valid then return end
  -- check if its a proper ltn signal
  if not config.ltn_signals[signal_name] then
    dlog("ltn_combinator:set '" .. tostring(signal_name) .. "' is not a ltn signal")
    return
  end

  local slot   = config.ltn_signals[signal_name].slot
  local signal = {
    signal = {
      type = "virtual",
      name = signal_name,
    },
    count = value
  }

  self.entity.get_or_create_control_behavior().set_signal(slot, signal)
end

-- ltn_combinator:get
--  @param  a signal name defined by LogisticTrainNetwork
--  returns integer value set in combinator OR default value
function ltn_combinator:get(signal_name)
  if not self.entity or not self.entity.valid then return 0 end
  if not config.ltn_signals[signal_name] or not self.entity then
    dlog("ltn_combinator:set " .. tostring(signal_name) .. " is not a ltn signal")
    return nil
  end

  local signal = self.entity.get_or_create_control_behavior().get_signal(config.ltn_signals[signal_name].slot)
  if not signal or not signal.signal then
    signal.count = config.ltn_signals[signal_name].default
  end
  return signal.count
end

-- ltn_combinator:set_slot
--  @param  slot number (integer: 1 .. 14)
--  @param  signal Factorio::Signal table
function ltn_combinator:set_slot(slot, signal)
  if not self.entity or not self.entity.valid then return end
  slot = self:_validate_slot(slot)
  if slot < 1 then return end

  self.entity.get_or_create_control_behavior().set_signal(slot, signal)
end

-- ltn_combinator:set_slot_value
--  @param  slot number (integer: 1 .. 14)
--  @param  slot value (integer: 32bit signed)
function ltn_combinator:set_slot_value(slot, value)
  if not self.entity or not self.entity.valid then return end
  slot = self:_validate_slot(slot)
  if slot < 1 then return end

  local control = self.entity.get_or_create_control_behavior()

  local signal = control.get_signal(slot)
  if not signal or not signal.signal then return end

  control.set_signal(slot, {signal = signal.signal, count = value})
end

-- ltn_combinator:get_slot
--  @param designated slot. integer between 1 .. 14
--  returns table of type Factorio::Signal
function ltn_combinator:get_slot(slot)
  if not self.entity or not self.entity.valid then return {signal=nil, count=0} end
  slot = self:_validate_slot(slot)
  if slot < 1 then return end

  return self.entity.get_or_create_control_behavior().get_signal(slot)
end

-- ltn_combinator:remove_slot
--  @param designated slot. integer between 1 .. 14
function ltn_combinator:remove_slot(slot)
  if not self.entity or not self.entity.valid then return end
  slot = self:_validate_slot(slot)
  if slot < 1 then return end

  self.entity.get_or_create_control_behavior().set_signal(slot, nil)
end

function ltn_combinator:_validate_slot(slot)
  if not slot then return -1 end
  slot = slot + config.ltnc_ltn_slot_count

  -- make sure slot is a valid number for a non-ltn signal
  if slot <= config.ltnc_ltn_slot_count or slot > config.ltnc_item_slot_count then
    dlog("Invalid slot number #" .. slot)
    return -1
  end

  return slot
end

--[[
        THIS IS THE END
--]] ----------------------------------------------------------------------------------
