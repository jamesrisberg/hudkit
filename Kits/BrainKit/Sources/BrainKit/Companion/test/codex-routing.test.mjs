import test from 'node:test';
import assert from 'node:assert/strict';
import { modelChoices, routeInput, discoverModels } from '../runtimes/codex-routing.mjs';
const model = (name, extra = {}) => ({ model: name, supportedReasoningEfforts: [{reasoningEffort:'low'}, {reasoningEffort:'medium'}], defaultReasoningEffort:'medium', ...extra });
const catalog = [model('gpt-6-astra', {isDefault:true}), model('gpt-5.6-luna')];
const choices = modelChoices(catalog);

test('simple tasks take low effort fast path; complex and destructive tasks retain stronger reasoning', () => {
  for (const input of ['What is the capital of France?', 'Create a note called groceries', 'Please open my downloads folder', 'Hello']) {
    const route = routeInput(input, choices);
    assert.equal(route.model, 'gpt-5.6-luna', input); assert.equal(route.effort, 'low');
  }
  for (const input of ['Debug the intermittent crash', 'What is the best investment for my retirement?', 'Delete my downloads', 'Please plan my move', 'Think carefully about the options', 'Can you help with something complicated?']) {
    assert.equal(routeInput(input, choices).model, 'gpt-6-astra', input);
  }
  assert.equal(routeInput('Go ahead', choices, {tier:'deep'}).tier, 'deep');
  assert.equal(routeInput('What is two plus two?', choices, {tier:'deep'}).tier, 'fast');
});
test('only advertised text models and supported reasoning efforts are used', () => {
  const fallback = modelChoices([model('gpt-5.6-luna', {hidden:true}), model('new-default', {isDefault:true,supportedReasoningEfforts:[{reasoningEffort:'high'}]})]);
  assert.equal(routeInput('Hello', fallback).model, 'new-default');
  assert.equal(routeInput('Hello', fallback).effort, 'high');
  assert.equal(routeInput('Hello', modelChoices()).model, null);
  assert.equal(modelChoices([model('gpt-5.6-luna', {upgradeInfo:{retirementAt:1}})]).fast, undefined);
});
test('model catalog discovery handles pages without a turn or repeated cursor loop', async () => {
  const calls = [];
  const runtime = { request: async (method, params) => { calls.push({method,params}); return calls.length === 1 ? {data:[catalog[0]],nextCursor:'page2'} : {data:[catalog[1]],nextCursor:'page2'}; } };
  assert.equal((await discoverModels(runtime)).fast.model, 'gpt-5.6-luna');
  assert.equal(calls.length, 2); assert.ok(calls.every(c => c.method === 'model/list'));
  assert.equal(calls[1].params.cursor, 'page2');
});
