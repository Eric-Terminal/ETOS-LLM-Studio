// ============================================================================
// RoleplayHTMLCompatibilityRuntime.swift
// ============================================================================
// ETOS LLM Studio
//
// 在基础 HTML 桥之上补齐酒馆助手事件与 MVU 公共接口。
// ============================================================================

import Foundation

enum RoleplayHTMLCompatibilityRuntime {
    static let source = #"""
(function () {
  const api = window.etos;
  if (!api) return;
  const clone = value => value === undefined ? undefined : JSON.parse(JSON.stringify(value));
  const pathParts = path => {
    if (Array.isArray(path)) return path.map(String);
    const source = String(path || '');
    const result = [];
    let index = 0;
    while (index < source.length) {
      if (source[index] === '.') { index += 1; continue; }
      if (source[index] === '[') {
        index += 1;
        while (/\s/.test(source[index] || '')) index += 1;
        let value = '';
        const quote = source[index] === '"' || source[index] === "'" ? source[index++] : null;
        while (index < source.length) {
          const character = source[index++];
          if (quote && character === '\\' && index < source.length) { value += source[index++]; continue; }
          if ((quote && character === quote) || (!quote && character === ']')) break;
          value += character;
        }
        while (index < source.length && source[index] !== ']') index += 1;
        if (source[index] === ']') index += 1;
        if (value.trim()) result.push(value.trim());
        continue;
      }
      let value = '';
      while (index < source.length && source[index] !== '.' && source[index] !== '[') value += source[index++];
      value = value.trim().replace(/^(["'])(.*)\1$/, '$2');
      if (value) result.push(value);
    }
    return result;
  };
  const getPath = (root, path, fallback = null) => {
    let value = root;
    for (const part of pathParts(path)) {
      if (value == null || !(part in Object(value))) return fallback;
      value = value[part];
    }
    return value;
  };
  const setPath = (root, path, value) => {
    const parts = pathParts(path);
    if (!parts.length) {
      if (value && typeof value === 'object') Object.assign(root, clone(value));
      return;
    }
    let target = root;
    for (const part of parts.slice(0, -1)) {
      if (target[part] == null || typeof target[part] !== 'object') target[part] = {};
      target = target[part];
    }
    target[parts.at(-1)] = clone(value);
  };
  const deletePath = (root, path) => {
    const parts = pathParts(path);
    if (!parts.length) return false;
    let target = root;
    for (const part of parts.slice(0, -1)) {
      if (target?.[part] == null || typeof target[part] !== 'object') return false;
      target = target[part];
    }
    const key = parts.at(-1);
    if (Array.isArray(target) && /^\d+$/.test(key)) {
      const index = Number(key);
      if (index < 0 || index >= target.length) return false;
      target.splice(index, 1);
      return true;
    }
    return delete target[key];
  };
  const variablePath = parts => parts.map(part => /^[^.[\]\/]+$/.test(part)
    ? part
    : `[${JSON.stringify(part)}]`
  ).join('.').replaceAll('.[', '[');
  const iframeEvents = Object.freeze({
    MESSAGE_IFRAME_RENDER_STARTED: 'message_iframe_render_started',
    MESSAGE_IFRAME_RENDER_ENDED: 'message_iframe_render_ended',
    GENERATION_STARTED: 'js_generation_started',
    STREAM_TOKEN_RECEIVED_FULLY: 'js_stream_token_received_fully',
    STREAM_TOKEN_RECEIVED_INCREMENTALLY: 'js_stream_token_received_incrementally',
    GENERATION_ENDED: 'js_generation_ended'
  });
  const names = [
    'APP_READY', 'EXTRAS_CONNECTED', 'MESSAGE_SWIPED', 'MESSAGE_SENT', 'MESSAGE_RECEIVED',
    'MESSAGE_EDITED', 'MESSAGE_DELETED', 'MESSAGE_UPDATED', 'MESSAGE_FILE_EMBEDDED',
    'MESSAGE_REASONING_EDITED', 'MESSAGE_REASONING_DELETED', 'MESSAGE_SWIPE_DELETED',
    'MORE_MESSAGES_LOADED', 'IMPERSONATE_READY', 'CHAT_CHANGED', 'GENERATION_AFTER_COMMANDS',
    'GENERATION_STARTED', 'GENERATION_STOPPED', 'GENERATION_ENDED', 'SD_PROMPT_PROCESSING',
    'EXTENSIONS_FIRST_LOAD', 'EXTENSION_SETTINGS_LOADED', 'SETTINGS_LOADED', 'SETTINGS_UPDATED',
    'MOVABLE_PANELS_RESET', 'SETTINGS_LOADED_BEFORE', 'SETTINGS_LOADED_AFTER',
    'CHATCOMPLETION_SOURCE_CHANGED', 'CHATCOMPLETION_MODEL_CHANGED', 'OAI_PRESET_CHANGED_BEFORE',
    'OAI_PRESET_CHANGED_AFTER', 'OAI_PRESET_EXPORT_READY', 'OAI_PRESET_IMPORT_READY',
    'WORLDINFO_SETTINGS_UPDATED', 'WORLDINFO_UPDATED', 'CHARACTER_EDITOR_OPENED', 'CHARACTER_EDITED',
    'CHARACTER_PAGE_LOADED', 'USER_MESSAGE_RENDERED', 'CHARACTER_MESSAGE_RENDERED',
    'FORCE_SET_BACKGROUND', 'CHAT_DELETED', 'CHAT_CREATED', 'GENERATE_BEFORE_COMBINE_PROMPTS',
    'GENERATE_AFTER_COMBINE_PROMPTS', 'GENERATE_AFTER_DATA', 'WORLD_INFO_ACTIVATED',
    'TEXT_COMPLETION_SETTINGS_READY', 'CHAT_COMPLETION_SETTINGS_READY', 'CHAT_COMPLETION_PROMPT_READY',
    'CHARACTER_FIRST_MESSAGE_SELECTED', 'CHARACTER_DELETED', 'CHARACTER_DUPLICATED',
    'CHARACTER_RENAMED', 'CHARACTER_RENAMED_IN_PAST_CHAT', 'SMOOTH_STREAM_TOKEN_RECEIVED',
    'STREAM_TOKEN_RECEIVED', 'STREAM_REASONING_DONE', 'FILE_ATTACHMENT_DELETED',
    'WORLDINFO_FORCE_ACTIVATE', 'OPEN_CHARACTER_LIBRARY', 'ONLINE_STATUS_CHANGED', 'IMAGE_SWIPED',
    'CONNECTION_PROFILE_LOADED', 'CONNECTION_PROFILE_CREATED', 'CONNECTION_PROFILE_DELETED',
    'CONNECTION_PROFILE_UPDATED', 'TOOL_CALLS_PERFORMED', 'TOOL_CALLS_RENDERED',
    'CHARACTER_MANAGEMENT_DROPDOWN', 'SECRET_WRITTEN', 'SECRET_DELETED', 'SECRET_ROTATED',
    'SECRET_EDITED', 'PRESET_CHANGED', 'PRESET_DELETED', 'PRESET_RENAMED',
    'PRESET_RENAMED_BEFORE', 'MAIN_API_CHANGED', 'WORLDINFO_ENTRIES_LOADED', 'WORLDINFO_SCAN_DONE',
    'MEDIA_ATTACHMENT_DELETED'
  ];
  const exceptional = {
    CHAT_CHANGED: 'chat_id_changed',
    GENERATION_AFTER_COMMANDS: 'GENERATION_AFTER_COMMANDS',
    CHARACTER_DELETED: 'characterDeleted',
    CHARACTER_MANAGEMENT_DROPDOWN: 'charManagementDropdown',
    SMOOTH_STREAM_TOKEN_RECEIVED: 'stream_token_received'
  };
  const tavernEvents = Object.freeze(Object.fromEntries(names.map(name => [name, exceptional[name] || name.toLowerCase()])));
  const mvuEvents = Object.freeze({
    VARIABLE_INITIALIZED: 'mag_variable_initialized',
    VARIABLE_INITIALIZED_LEGACY: 'mag_variable_initiailized',
    VARIABLE_UPDATE_STARTED: 'mag_variable_update_started',
    COMMAND_PARSED: 'mag_command_parsed',
    VARIABLE_UPDATE_ENDED: 'mag_variable_update_ended',
    BEFORE_MESSAGE_UPDATE: 'mag_before_message_update',
    SINGLE_VARIABLE_UPDATED: 'mag_variable_updated'
  });
  const splitArguments = source => {
    const result = [];
    let current = '', quote = null, escaped = false, depth = 0;
    for (const character of String(source || '')) {
      if (quote) {
        current += character;
        if (escaped) escaped = false;
        else if (character === '\\') escaped = true;
        else if (character === quote) quote = null;
      } else if (character === '"' || character === "'" || character === '`') {
        quote = character;
        current += character;
      } else if ('[{('.includes(character)) {
        depth += 1;
        current += character;
      } else if (']})'.includes(character)) {
        depth = Math.max(0, depth - 1);
        current += character;
      } else if (character === ',' && depth === 0) {
        result.push(current.trim());
        current = '';
      } else current += character;
    }
    if (current.trim()) result.push(current.trim());
    return result;
  };
  const literal = source => {
    const text = String(source ?? '').trim();
    if (!text) return undefined;
    try { return JSON.parse(text); } catch (_) {}
    try { return Function(`"use strict"; return (${text});`)(); } catch (_) { return text; }
  };
  const statPath = path => {
    const normalized = String(path || '').replace(/^stat_data\.?/, '');
    return normalized ? `stat_data.${normalized}` : 'stat_data';
  };
  const schemaAt = (schema, path) => {
    let current = schema?.properties?.stat_data || schema;
    for (const part of pathParts(String(path || '').replace(/^stat_data\.?/, ''))) {
      if (!current || typeof current !== 'object') return null;
      if (current.type === 'array') {
        const index = Number(part);
        current = Array.isArray(current.prefixItems) && Number.isInteger(index)
          ? current.prefixItems[index] || current.items
          : current.items;
      } else current = current.properties?.[part];
    }
    return current || null;
  };
  const schemaAllowsInsertion = (data, path, key) => {
    if (data.schema?.['x-etos-generated']) return true;
    const schema = schemaAt(data.schema, path);
    if (!schema) return true;
    if (schema.type === 'array') {
      return schema.extensible !== false && (!schema.prefixItems || schema.extensible === true);
    }
    if (schema.type !== 'object') return false;
    if (key != null && schema.properties?.[String(key)]) return true;
    return schema.extensible !== false && schema.additionalProperties !== false;
  };
  const schemaAllowsDeletion = (data, path, key) => {
    if (data.schema?.['x-etos-generated']) return true;
    const schema = schemaAt(data.schema, path);
    if (!schema) return true;
    if (schema.type === 'array') {
      return schema.extensible !== false && (!schema.prefixItems || schema.extensible === true);
    }
    if (schema.type !== 'object' || key == null) return false;
    const property = schema.properties?.[String(key)];
    return property?.required !== true && !(schema.required || []).includes(String(key));
  };
  const parseCommands = message => {
    const commands = [];
    const source = String(message || '');
    const regex = /_\.(set|add|insert|assign|delete|remove|unset|move)\s*\(/gi;
    let match;
    while ((match = regex.exec(source))) {
      const argumentStart = regex.lastIndex;
      let quote = null, escaped = false, depth = 1, cursor = argumentStart;
      for (; cursor < source.length && depth > 0; cursor += 1) {
        const character = source[cursor];
        if (quote) {
          if (escaped) escaped = false;
          else if (character === '\\') escaped = true;
          else if (character === quote) quote = null;
        } else if (character === '"' || character === "'" || character === '`') quote = character;
        else if (character === '(') depth += 1;
        else if (character === ')') depth -= 1;
      }
      if (depth !== 0) break;
      const argumentEnd = cursor - 1;
      while (source[cursor] === ' ' || source[cursor] === '\t') cursor += 1;
      if (source[cursor] !== ';') { regex.lastIndex = argumentEnd + 1; continue; }
      cursor += 1;
      const lineEnd = source.indexOf('\n', cursor);
      const suffix = source.slice(cursor, lineEnd < 0 ? source.length : lineEnd);
      const reason = suffix.match(/^\s*\/\/\s*(.*)$/)?.[1] || '';
      const parsedType = match[1].toLowerCase();
      commands.push({
        offset: match.index,
        type: parsedType === 'assign' ? 'insert' : parsedType === 'unset' ? 'delete' : parsedType,
        full_match: source.slice(match.index, cursor),
        args: splitArguments(source.slice(argumentStart, argumentEnd)).map(literal),
        reason
      });
      regex.lastIndex = cursor;
    }
    const patchRegex = /<(json_?patch)\b[^>]*>([\s\S]*?)<\/\1>/gi;
    while ((match = patchRegex.exec(source))) {
      let operations;
      const patchBody = match[2].trim().replace(/^```[^\n]*\n([\s\S]*?)\n```$/, '$1').trim();
      try { operations = JSON.parse(patchBody); }
      catch (_) {
        try { operations = window.YAML?.parse?.(patchBody); }
        catch (_) { operations = []; }
      }
      for (const [operationIndex, operation] of (Array.isArray(operations) ? operations : []).entries()) {
        const offset = match.index + operationIndex;
        const path = variablePath(String(operation.path || operation.to || '').replace(/^\//, '').split('/').map(value => value.replaceAll('~1', '/').replaceAll('~0', '~')));
        if (operation.op === 'replace') commands.push({ offset, type: 'set', full_match: JSON.stringify(operation), args: [path, operation.value], reason: 'json_patch' });
        else if (operation.op === 'delta') commands.push({ offset, type: 'add', full_match: JSON.stringify(operation), args: [path, operation.value], reason: 'json_patch' });
        else if (operation.op === 'insert' || operation.op === 'add') {
          const parts = pathParts(path);
          commands.push({
            offset,
            type: 'insert',
            full_match: JSON.stringify(operation),
            args: [variablePath(parts.slice(0, -1)), parts.at(-1), operation.value],
            reason: 'json_patch'
          });
        } else if (operation.op === 'remove') commands.push({ offset, type: 'delete', full_match: JSON.stringify(operation), args: [path], reason: 'json_patch' });
        else if (operation.op === 'move') {
          const from = variablePath(String(operation.from || '').replace(/^\//, '').split('/').map(value => value.replaceAll('~1', '/').replaceAll('~0', '~')));
          commands.push({ offset, type: 'move', full_match: JSON.stringify(operation), args: [from, path], reason: 'json_patch' });
        }
      }
    }
    return commands.sort((lhs, rhs) => lhs.offset - rhs.offset).map(({ offset: _, ...command }) => command);
  };
  const applyCommand = (data, command) => {
    const [path, ...args] = command.args || [];
    const targetPath = statPath(path);
    switch (command.type) {
      case 'set': {
        const current = getPath(data, targetPath, undefined);
        if (current === undefined) break;
        let value = args.length >= 2 ? args[1] : args[0];
        if (args.length >= 2 && JSON.stringify(Array.isArray(current) && current.length === 2 && typeof current[1] === 'string' ? current[0] : current) !== JSON.stringify(args[0])) break;
        const comparable = Array.isArray(current) && current.length === 2 && typeof current[1] === 'string' ? current[0] : current;
        if (typeof comparable === 'number' && value !== null && !Number.isNaN(Number(value))) value = Number(value);
        if (Array.isArray(current) && current.length === 2 && typeof current[1] === 'string') setPath(data, targetPath, [value, current[1]]);
        else setPath(data, targetPath, value);
        break;
      }
      case 'add':
        {
          const current = getPath(data, targetPath, undefined);
          if (current === undefined) break;
          const actual = Array.isArray(current) && current.length === 2 && typeof current[1] === 'string' ? current[0] : current;
          let updated;
          const date = typeof actual === 'string' && Number.isNaN(Number(actual)) ? new Date(actual) : null;
          if (date && !Number.isNaN(date.getTime())) updated = new Date(date.getTime() + Number(args[0] || 0)).toISOString();
          else if (typeof actual === 'number' && !Number.isNaN(Number(args[0]))) updated = Number((actual + Number(args[0])).toPrecision(12));
          else break;
          if (Array.isArray(current) && current.length === 2 && typeof current[1] === 'string') setPath(data, targetPath, [updated, current[1]]);
          else setPath(data, targetPath, updated);
        }
        break;
      case 'insert': {
        const current = getPath(data, targetPath, null);
        const key = args.length >= 2 ? args[0] : null;
        const value = args.length >= 2 ? args[1] : args[0];
        if (!schemaAllowsInsertion(data, path, key)) break;
        if (Array.isArray(current)) current.splice(key == null || key === '-' ? current.length : Math.max(0, Number(key)), 0, clone(value));
        else if (current && typeof current === 'object' && key != null) current[String(key)] = clone(value);
        else if (current && typeof current === 'object' && value && typeof value === 'object' && !Array.isArray(value)) Object.assign(current, clone(value));
        else if (current == null && key != null) setPath(data, `${targetPath}.${key}`, value);
        break;
      }
      case 'delete':
      case 'remove': {
        if (!args.length) {
          const parts = pathParts(path);
          const containerPath = variablePath(parts.slice(0, -1));
          if (schemaAllowsDeletion(data, containerPath, parts.at(-1))) deletePath(data, targetPath);
        }
        else {
          const current = getPath(data, targetPath, null);
          if (!schemaAllowsDeletion(data, path, args[0])) break;
          if (Array.isArray(current)) {
            const index = Number(args[0]);
            if (Number.isInteger(index) && index >= 0 && index < current.length) current.splice(index, 1);
            else {
              const encoded = JSON.stringify(args[0]);
              for (let index = current.length - 1; index >= 0; index--) if (JSON.stringify(current[index]) === encoded) current.splice(index, 1);
            }
          } else if (current && typeof current === 'object') delete current[String(args[0])];
        }
        break;
      }
      case 'move': {
        if (typeof args[0] !== 'string') break;
        const value = getPath(data, targetPath, undefined);
        if (value === undefined) break;
        setPath(data, statPath(args[0]), value);
        deletePath(data, targetPath);
        break;
      }
    }
  };
  const mvu = {
    events: mvuEvents,
    getMvuData: (option = { type: 'chat' }) => {
      const data = api.getVariables(option);
      if (!data.stat_data) data.stat_data = {};
      if (!data.initialized_lorebooks) data.initialized_lorebooks = {};
      return data;
    },
    replaceMvuData: async (data, option = { type: 'chat' }) => {
      api.replaceVariables(data, option);
    },
    parseMessage: async (message, oldData) => {
      const before = clone(oldData || { stat_data: {}, initialized_lorebooks: {} });
      const updated = clone(before);
      await api.eventEmitAndWait(mvuEvents.VARIABLE_UPDATE_STARTED, updated);
      const commands = parseCommands(message);
      await api.eventEmitAndWait(mvuEvents.COMMAND_PARSED, updated, commands, String(message || ''));
      updated.display_data = clone(before.stat_data || {});
      updated.delta_data = {};
      for (const command of commands) {
        const rawPath = command.args?.[0] ?? '';
        const targetPath = statPath(rawPath);
        const oldValue = clone(getPath(updated, targetPath, undefined));
        applyCommand(updated, command);
        const newValue = clone(getPath(updated, targetPath, undefined));
        if (JSON.stringify(oldValue) === JSON.stringify(newValue)) continue;
        const visibleOld = Array.isArray(oldValue) && oldValue.length === 2 && typeof oldValue[1] === 'string' ? oldValue[0] : oldValue;
        const visibleNew = Array.isArray(newValue) && newValue.length === 2 && typeof newValue[1] === 'string' ? newValue[0] : newValue;
        const displayPath = String(rawPath).replace(/^stat_data\.?/, '');
        const description = `${JSON.stringify(visibleOld)}->${JSON.stringify(visibleNew)}${command.reason ? ` (${command.reason})` : ''}`;
        if (displayPath) {
          setPath(updated.display_data, displayPath, description);
          setPath(updated.delta_data, displayPath, description);
        }
        await api.eventEmitAndWait(
          mvuEvents.SINGLE_VARIABLE_UPDATED,
          updated.stat_data,
          displayPath,
          oldValue,
          newValue
        );
      }
      await api.eventEmitAndWait(mvuEvents.VARIABLE_UPDATE_ENDED, updated, before);
      return updated;
    },
    getCurrentMvuData: () => mvu.getMvuData({ type: 'message', message_id: api.getCurrentMessageId() }),
    replaceCurrentMvuData: data => mvu.replaceMvuData(data, { type: 'message', message_id: api.getCurrentMessageId() }),
    reloadInitVar: async data => {
      const names = window.getCharWorldbookNames?.('current') || {};
      const lorebooks = [names.primary, ...(names.additional || [])].filter(Boolean);
      data.initialized_lorebooks ||= {};
      data.stat_data ||= {};
      let changed = false;
      for (const name of lorebooks) {
        if (Object.prototype.hasOwnProperty.call(data.initialized_lorebooks, name)) continue;
        const entries = await window.getLorebookEntries?.(name) || [];
        const initialized = [];
        for (const entry of entries) {
          if (!String(entry.name || entry.comment || '').toLowerCase().includes('[initvar]')) continue;
          try {
            const parsed = window.YAML?.parse?.(window.substitudeMacros?.(entry.content) || entry.content) || {};
            data.stat_data = { ...parsed, ...data.stat_data };
            initialized.push(entry.uid ?? entry.id);
            changed = true;
          } catch (error) { console.error(error); }
        }
        data.initialized_lorebooks[name] = initialized;
      }
      return changed;
    },
    getMvuVariable: (data, path, { category = 'stat', default_value = undefined } = {}) => {
      const record = data?.[`${category}_data`] || {};
      const value = getPath(record, path, default_value);
      return Array.isArray(value) && value.length === 2 && typeof value[1] === 'string' ? value[0] : value;
    },
    getRecordFromMvuData: (data, category) => data?.[`${category}_data`] || {},
    setMvuVariable: async (data, path, value, { reason = '', is_recursive = false } = {}) => {
      data.stat_data ||= {};
      const current = getPath(data.stat_data, path, undefined);
      if (current === undefined) return false;
      const oldValue = clone(current);
      const actual = Array.isArray(current) && current.length === 2 && typeof current[1] === 'string'
        ? [value, current[1]] : value;
      setPath(data.stat_data, path, actual);
      const description = `${JSON.stringify(Array.isArray(oldValue) && oldValue.length === 2 ? oldValue[0] : oldValue)}->${JSON.stringify(value)}${reason ? ` (${reason})` : ''}`;
      if (data.display_data) setPath(data.display_data, path, description);
      if (data.delta_data) setPath(data.delta_data, path, description);
      if (is_recursive) await api.eventEmitAndWait(mvuEvents.SINGLE_VARIABLE_UPDATED, data.stat_data, path, oldValue, actual);
      return true;
    },
    isDuringExtraAnalysis: () => false,
    get: path => clone(getPath(api.getAllVariables(), path, null)),
    set: (path, value) => api.setVariable(path, value, { type: 'message', message_id: 'latest' }),
    variables: () => api.getAllVariables()
  };
  mvu.api = {
    addCommands: commands => Promise.resolve().then(async () => {
      const option = { type: 'message', message_id: 'latest' };
      const updated = mvu.getMvuData(option);
      const normalized = (Array.isArray(commands) ? commands : [commands]).flatMap(command =>
        typeof command === 'string' ? parseCommands(command) : [command]
      );
      await api.eventEmitAndWait(mvuEvents.COMMAND_PARSED, updated, normalized, '');
      normalized.forEach(command => applyCommand(updated, command));
      await mvu.replaceMvuData(updated, option);
      return updated;
    })
  };
  window.Mvu = Object.assign(window.Mvu || {}, mvu);
  const variableSchemas = {};
  window.registerVariableSchema = (schema, { type = 'message' } = {}) => {
    variableSchemas[type] = schema;
    let exported = null;
    try {
      exported = window.z?.toJSONSchema?.(schema, { io: 'input', unrepresentable: 'any' });
    } catch (error) {
      console.warn('[ETOS MVU] Zod schema 无法完整转换为 JSON Schema', error);
    }
    if (exported) {
      exported['x-etos-zod-schema'] = true;
      const option = type === 'message'
        ? { type, message_id: api.getCurrentMessageId() }
        : { type };
      const variables = api.getVariables(option);
      variables.schema = exported;
      api.replaceVariables(variables, option);
    }
    return schema;
  };
  window.getVariableSchema = (type = 'message') => variableSchemas[type];
  api.eventOn(mvuEvents.VARIABLE_UPDATE_ENDED, async variables => {
    const schema = variableSchemas.message;
    if (!schema?.safeParseAsync) return;
    const parsed = await schema.safeParseAsync(variables);
    if (!parsed.success) return;
    const option = { type: 'message', message_id: api.getCurrentMessageId() };
    const current = api.getVariables(option);
    api.replaceVariables({ ...current, ...parsed.data }, option);
  });
  window.getTavernHelperVersion = async () => '4.7.12';
  window.toastr ||= Object.freeze({
    info: (message, title = '') => console.info(title, message),
    success: (message, title = '') => console.info(title, message),
    warning: (message, title = '') => console.warn(title, message),
    error: (message, title = '') => console.error(title, message)
  });
  window.TavernHelper.registerVariableSchema = window.registerVariableSchema;
  window.iframe_events = iframeEvents;
  window.tavern_events = tavernEvents;
  window.waitGlobalInitialized = name => new Promise(resolve => {
    if (window[name] !== undefined && window[name] !== null) return resolve(window[name]);
    const timer = setInterval(() => {
      if (window[name] !== undefined && window[name] !== null) {
        clearInterval(timer);
        resolve(window[name]);
      }
    }, 10);
  });
  window.initializeGlobal = (name, value) => {
    window[name] = value;
    api.eventEmit(`global_${name}_initialized`);
    return value;
  };
  window.errorCatched = callback => async (...args) => {
    try { return await callback(...args); } catch (error) { console.error(error); throw error; }
  };
  const builtinPromptDefaultOrder = Object.freeze([
    'world_info_before', 'persona_description', 'char_description', 'char_personality',
    'scenario', 'world_info_after', 'dialogue_examples', 'chat_history', 'user_input'
  ]);
  api.builtin_prompt_default_order = builtinPromptDefaultOrder;
  window.builtin_prompt_default_order = builtinPromptDefaultOrder;
  const pendingRequests = new Map();
  const nativeRequest = (action, payload) => new Promise((resolve, reject) => {
    const requestID = window.crypto?.randomUUID?.() || `${Date.now()}-${Math.random()}`;
    pendingRequests.set(requestID, { resolve, reject });
    try {
      window.webkit?.messageHandlers?.etosRoleplay?.postMessage({ action, request_id: requestID, ...payload });
    } catch (error) {
      pendingRequests.delete(requestID);
      reject(error);
    }
  });
  window.__etosResolveRequest = (requestID, result, error) => {
    const pending = pendingRequests.get(requestID);
    if (!pending) return;
    pendingRequests.delete(requestID);
    if (error) pending.reject(new Error(String(error)));
    else pending.resolve(result);
  };
  const generate = async (config = {}, raw = false) => {
    const generationID = config.generation_id || window.crypto?.randomUUID?.() || `${Date.now()}-${Math.random()}`;
    await api.eventEmitAndWait(iframeEvents.GENERATION_STARTED, generationID);
    await api.eventEmitAndWait(tavernEvents.GENERATION_STARTED, generationID);
    try {
      const serializable = JSON.parse(JSON.stringify(config, (_key, value) => value instanceof File ? undefined : value));
      const text = String(await nativeRequest('generate_text', { config: serializable, raw }));
      if (config.should_stream === true) {
        await api.eventEmitAndWait(iframeEvents.STREAM_TOKEN_RECEIVED_FULLY, text, generationID);
        await api.eventEmitAndWait(iframeEvents.STREAM_TOKEN_RECEIVED_INCREMENTALLY, text, generationID);
      }
      await api.eventEmitAndWait(iframeEvents.GENERATION_ENDED, text, generationID);
      await api.eventEmitAndWait(tavernEvents.GENERATION_ENDED, generationID);
      return text;
    } catch (error) {
      await api.eventEmitAndWait(tavernEvents.GENERATION_STOPPED, generationID);
      throw error;
    }
  };
  api.generate = config => generate(config, false);
  api.generateRaw = config => generate(config, true);
  window.generate = api.generate;
  window.generateRaw = api.generateRaw;
  window.TavernHelper.generate = api.generate;
  window.TavernHelper.generateRaw = api.generateRaw;
  window.addEventListener('DOMContentLoaded', () => {
    setTimeout(async () => {
      const option = { type: 'message', message_id: 'latest' };
      const data = mvu.getMvuData(option);
      const original = clone(data);
      const before = JSON.stringify(data);
      await api.eventEmitAndWait(mvuEvents.VARIABLE_INITIALIZED, data, 0);
      await api.eventEmitAndWait(mvuEvents.VARIABLE_INITIALIZED_LEGACY, data, 0);
      await api.eventEmitAndWait(mvuEvents.VARIABLE_UPDATE_ENDED, data, original);
      if (JSON.stringify(data) !== before) api.replaceVariables(data, option);
    }, 0);
  });
})();
"""#
}
