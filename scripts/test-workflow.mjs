// Проверка логики сценария: берёт настоящий код из workflows/max-bot-menu.json
// и прогоняет его на фикстурах. Дублирования нет — тестируется то, что уедет в n8n.
// Запуск: make test
import { readFileSync } from 'node:fs';
import assert from 'node:assert/strict';

const wf = JSON.parse(readFileSync(new URL('../workflows/max-bot-menu.json', import.meta.url), 'utf8'));
const code = (name) => wf.nodes.find((n) => n.name === name).parameters.jsCode;

// Мини-песочница вместо рантайма n8n.
function run(js, { json, items, staticData }) {
  const $getWorkflowStaticData = () => staticData;
  const $input = { first: () => ({ json: items?.[0] ?? json }), all: () => (items ?? [json]).map((j) => ({ json: j })) };
  const fn = new Function('$getWorkflowStaticData', '$input', '$json', `${js}`);
  return fn($getWorkflowStaticData, $input, json);
}

const parse = code('Разобрать updates');
const menu = code('Меню');
const echo = code('Эхо-ответ');

// --- 1. marker сохраняется, групповые чаты отбрасываются ---------------------
const store = {};
const out = run(parse, {
  staticData: store,
  items: [{
    marker: 777,
    updates: [
      { update_type: 'message_created', message: { recipient: { chat_type: 'chat', chat_id: -69087849477592 }, sender: { user_id: 5, name: 'Житель' }, body: { text: 'привет' } } },
      { update_type: 'message_created', message: { recipient: { chat_type: 'dialog', chat_id: 42, user_id: 7 }, sender: { user_id: 7, first_name: 'Никита' }, body: { text: '/start' } } },
      { update_type: 'message_created', message: { recipient: { chat_type: 'dialog', chat_id: 43 }, sender: { user_id: 9, name: 'Бот', is_bot: true }, body: { text: 'спам' } } },
    ],
  }],
});
assert.equal(store.marker, 777, 'marker должен сохраняться в статических данных');
assert.equal(out.length, 1, 'должен остаться только личный диалог от человека');
assert.deepEqual(
  { kind: out[0].json.kind, chat_id: out[0].json.chat_id, name: out[0].json.name, text: out[0].json.text },
  { kind: 'message', chat_id: 42, name: 'Никита', text: '/start' },
);

// --- 2. callback приводится к общей структуре -------------------------------
const cbOut = run(parse, {
  staticData: {},
  items: [{ marker: 778, updates: [{ update_type: 'message_callback', callback: { callback_id: 'cb1', payload: 'catalog', user: { user_id: 7, first_name: 'Никита' } }, message: { recipient: { chat_type: 'dialog', chat_id: 42, user_id: 7 } } }] }],
});
assert.equal(cbOut[0].json.kind, 'callback');
assert.equal(cbOut[0].json.payload, 'catalog');
assert.equal(cbOut[0].json.callback_id, 'cb1');

// --- 3. обычное сообщение -> POST /messages с клавиатурой -------------------
const main = run(menu, { staticData: {}, json: { kind: 'message', chat_id: 42, name: 'Никита', text: '/start' } })[0].json;
assert.equal(main.api_path, 'messages');
assert.equal(main.api_query.chat_id, '42');
assert.ok(main.body.text.includes('Никита'), 'имя должно подставляться вместо {name}');
const kb = main.body.attachments.find((a) => a.type === 'inline_keyboard');
assert.ok(kb && Array.isArray(kb.payload.buttons) && kb.payload.buttons.length >= 2);
for (const row of kb.payload.buttons) {
  for (const b of row) {
    assert.ok(b.text, 'у каждой кнопки обязателен text');
    if (b.type === 'callback') assert.ok(b.payload, 'у callback-кнопки обязателен payload');
    if (b.type === 'link') assert.ok(b.url, 'у link-кнопки обязателен url');
  }
}

// --- 4. callback -> POST /answers, сообщение меняется на месте --------------
const ans = run(menu, { staticData: {}, json: { kind: 'callback', chat_id: 42, name: 'Никита', payload: 'catalog', callback_id: 'cb1' } })[0].json;
assert.equal(ans.api_path, 'answers');
assert.equal(ans.api_query.callback_id, 'cb1');
assert.ok(ans.body.message.attachments[0].payload.buttons.flat().some((b) => b.payload === 'main'), 'в подменю должна быть кнопка «Назад»');

// --- 5. динамический экран товара ------------------------------------------
const item = run(menu, { staticData: {}, json: { kind: 'callback', chat_id: 42, name: 'Н', payload: 'item:b', callback_id: 'cb2' } })[0].json;
assert.ok(item.body.message.text.includes('B'), 'экран товара строится из payload');

// --- 6. неизвестный payload не роняет сценарий -----------------------------
const unknown = run(menu, { staticData: {}, json: { kind: 'callback', chat_id: 42, name: 'Н', payload: 'нет-такого', callback_id: 'cb3' } })[0].json;
assert.equal(unknown.api_path, 'answers');
assert.ok(unknown.body.message.text.length > 0, 'должен быть фолбэк на главное меню');

// --- 7. ветка «эхо» ---------------------------------------------------------
const e = run(echo, { staticData: {}, json: { kind: 'message', chat_id: 42, name: 'Н', text: 'эхо тест 123' } })[0].json;
assert.equal(e.api_path, 'messages');
assert.ok(e.body.text.includes('тест 123') && !e.body.text.includes('эхо тест'), 'префикс «эхо » должен срезаться');

console.log('OK: 7 проверок пройдено');
