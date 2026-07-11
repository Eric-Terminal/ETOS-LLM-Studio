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
  const pathParts = path => String(path || '').replaceAll('[', '.').replaceAll(']', '').split('.').filter(Boolean);
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
    if (!parts.length) return;
    let target = root;
    for (const part of parts.slice(0, -1)) {
      if (target[part] == null || typeof target[part] !== 'object') target[part] = {};
      target = target[part];
    }
    target[parts.at(-1)] = clone(value);
  };
  const deletePath = (root, path) => {
    const parts = pathParts(path);
    let target = root;
    for (const part of parts.slice(0, -1)) {
      if (target?.[part] == null || typeof target[part] !== 'object') return false;
      target = target[part];
    }
    return parts.length ? delete target[parts.at(-1)] : false;
  };
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
    VARIABLE_INITIALIZED: 'mag_variable_initiailized',
    VARIABLE_UPDATE_STARTED: 'mag_variable_update_started',
    COMMAND_PARSED: 'mag_command_parsed',
    VARIABLE_UPDATE_ENDED: 'mag_variable_update_ended',
    BEFORE_MESSAGE_UPDATE: 'mag_before_message_update'
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
      } else if (character === '"' || character === "'") {
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
  const parseCommands = message => {
    const commands = [];
    const source = String(message || '');
    const regex = /_\.(set|add|insert|delete|remove|move)\s*\(/gi;
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
        } else if (character === '"' || character === "'") quote = character;
        else if (character === '(') depth += 1;
        else if (character === ')') depth -= 1;
      }
      if (depth !== 0) break;
      const argumentEnd = cursor - 1;
      if (source[cursor] === ';') cursor += 1;
      const lineEnd = source.indexOf('\n', cursor);
      const suffix = source.slice(cursor, lineEnd < 0 ? source.length : lineEnd);
      const reason = suffix.match(/^\s*\/\/\s*(.*)$/)?.[1] || '';
      commands.push({
        type: match[1].toLowerCase(),
        full_match: source.slice(match.index, cursor),
        args: splitArguments(source.slice(argumentStart, argumentEnd)).map(literal),
        reason
      });
      regex.lastIndex = cursor;
    }
    return commands;
  };
  const applyCommand = (data, command) => {
    const [path, ...args] = command.args || [];
    const targetPath = statPath(path);
    switch (command.type) {
      case 'set': {
        const value = args.length >= 2 ? args[1] : args[0];
        if (args.length < 2 || JSON.stringify(getPath(data, targetPath)) === JSON.stringify(args[0])) setPath(data, targetPath, value);
        break;
      }
      case 'add':
        setPath(data, targetPath, Number(getPath(data, targetPath, 0)) + Number(args[0] || 0));
        break;
      case 'insert': {
        const current = getPath(data, targetPath, null);
        const key = args.length >= 2 ? args[0] : null;
        const value = args.length >= 2 ? args[1] : args[0];
        if (Array.isArray(current)) current.splice(key == null ? current.length : Math.max(0, Number(key)), 0, clone(value));
        else if (current && typeof current === 'object' && key != null) current[String(key)] = clone(value);
        else setPath(data, key == null ? targetPath : `${targetPath}.${key}`, value);
        break;
      }
      case 'delete':
      case 'remove': {
        if (!args.length) deletePath(data, targetPath);
        else {
          const current = getPath(data, targetPath, null);
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
      const before = mvu.getMvuData(option);
      await api.eventEmitAndWait(mvuEvents.BEFORE_MESSAGE_UPDATE, { variables: data, message_content: '' });
      api.replaceVariables(data, option);
      await api.eventEmitAndWait(mvuEvents.VARIABLE_UPDATE_ENDED, data, before);
    },
    parseMessage: async (message, oldData) => {
      const before = clone(oldData || { stat_data: {}, initialized_lorebooks: {} });
      const updated = clone(before);
      await api.eventEmitAndWait(mvuEvents.VARIABLE_UPDATE_STARTED, updated);
      const commands = parseCommands(message);
      await api.eventEmitAndWait(mvuEvents.COMMAND_PARSED, updated, commands, String(message || ''));
      commands.forEach(command => applyCommand(updated, command));
      await api.eventEmitAndWait(mvuEvents.VARIABLE_UPDATE_ENDED, updated, before);
      return commands.length ? updated : undefined;
    },
    getMvuVariable: (data, path, { default_value = null } = {}) => {
      const value = getPath(data, statPath(path), default_value);
      return Array.isArray(value) && value.length === 2 && typeof value[1] === 'string' ? value[0] : value;
    },
    setMvuVariable: (data, path, value) => { setPath(data, statPath(path), value); return data; },
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
  window.initializeGlobal = (name, value) => { window[name] = value; return value; };
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
      await api.eventEmitAndWait(mvuEvents.VARIABLE_UPDATE_ENDED, data, original);
      if (JSON.stringify(data) !== before) api.replaceVariables(data, option);
    }, 0);
  });
})();
"""#
}
