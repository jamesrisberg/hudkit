// Routing is local and advisory: it never grants access or starts a second turn.
// Every choice is checked against the runtime's current model catalog.
export function modelChoices(catalog = []) {
  const available = catalog.filter(m => !m.hidden && typeof m.model === 'string' &&
    (!m.inputModalities || m.inputModalities.includes('text')) &&
    !(m.upgradeInfo?.retirementAt && m.upgradeInfo.retirementAt * 1000 <= Date.now()));
  const find = names => names.map(name => available.find(m => m.model === name)).find(Boolean);
  const fallback = available.find(m => m.isDefault) ?? available[0];
  return {
    fast: find(['gpt-5.6-luna', 'gpt-5.4-mini', 'gpt-5.6-sol']) ?? fallback,
    deep: find(['gpt-6-astra', 'gpt-5.6-sol', 'gpt-5.5']) ?? fallback,
  };
}

export function routeInput(text, choices, previousRoute = null) {
  const input = text.trim().toLowerCase();
  const words = input.split(/\s+/).length;
  // Stakes and complexity take precedence over a request for speed. These rules
  // choose reasoning capacity only; the runtime still enforces all permissions.
  const complex = /\b(debug|diagnos\w*|refactor|implement|architect\w*|codebase|security|vulnerabilit\w*|deploy|migrat\w*|research|investigat\w*|analy[sz]\w*|compare|trade.?offs?|strategy|plan|design|reason|prove|medical|medication|legal|tax|invest\w*|financial|delete|remove|overwrite|erase|wipe|recursive|recursively)\b/.test(input);
  const deliberate = /\b(think (hard|carefully|deeply)|use (the )?(smart|strong|deep|powerful) (model|agent)|take your time)\b/.test(input);
  // An elliptical follow-up to deep work should not silently lose reasoning.
  const continuation = previousRoute?.tier === 'deep' && words <= 16 &&
    /^(yes|no|okay|ok|sure|continue|go ahead|do (it|that)|try again|what about|and |also |now |that |it |make (it|that)|fix (it|that))\b/.test(input);
  const straightforward = words <= 60 && (
    /^(hi|hello|hey|thanks|thank you|good (morning|afternoon|evening)|tell me a joke)\b/.test(input) ||
    /^(what('s| is| are)|who('s| is)|when (is|was)|where is|how (many|much)|tell me (the|what))\b/.test(input) ||
    /^(please )?(open|show|read|list|find|search for|create|make|write|save|append|add|rename|move|copy|set|turn|play|pause|stop|summarize|translate)\b/.test(input)
  );
  const tier = complex || deliberate || continuation || !straightforward ? 'deep' : 'fast';
  const selected = choices[tier];
  if (!selected) return { tier: 'default', model: null, effort: null, reason: 'Runtime model discovery unavailable; using its configured model' };
  const supported = selected.supportedReasoningEfforts?.map(e => e.reasoningEffort) ?? [];
  const preferred = tier === 'fast' ? ['low', 'minimal', 'none'] : ['medium', 'high', 'low'];
  const effort = preferred.find(e => supported.includes(e)) ??
    (supported.includes(selected.defaultReasoningEffort) ? selected.defaultReasoningEffort : supported[0]) ?? null;
  return { tier, model: selected.model, effort,
    reason: continuation ? 'Continuing a complex request' : tier === 'fast' ? 'Straightforward request' : 'Complex or open-ended request' };
}

export async function discoverModels(runtime) {
  const models = []; const cursors = new Set();
  let cursor;
  // A bounded catalog fetch happens at connection time, never on the voice path.
  for (let page = 0; page < 10; page++) {
    const result = await runtime.request('model/list', { limit: 100, includeHidden: false, ...(cursor ? { cursor } : {}) });
    if (!Array.isArray(result.data)) return modelChoices();
    models.push(...result.data);
    cursor = result.nextCursor;
    if (!cursor || cursors.has(cursor)) break;
    cursors.add(cursor);
  }
  return modelChoices(models);
}
