// Проверка логики сценариев: берёт настоящий код из workflows/*.json и
// прогоняет его на фикстурах. Дублирования нет — тестируется то, что уедет в n8n.
// Запуск: make test
import { readFileSync } from 'node:fs';
import assert from 'node:assert/strict';

const load = (f) => JSON.parse(readFileSync(new URL(`../workflows/${f}`, import.meta.url), 'utf8'));
const core = load('max-bot-core.json');
const poll = load('max-bot-polling.json');
const hook = load('max-bot-webhook.json');

const nodeOf = (wf, name) => {
  const n = wf.nodes.find((x) => x.name === name);
  assert.ok(n, `в ${wf.name} нет ноды «${name}»`);
  return n;
};
const code = (wf, name) => nodeOf(wf, name).parameters.jsCode;

// Мини-песочница вместо рантайма n8n.
function run(js, { json, items, env = {} }) {
  const $input = { first: () => ({ json: items?.[0] ?? json }), all: () => (items ?? [json]).map((j) => ({ json: j })) };
  const fn = new Function('$input', '$json', '$env', js);
  return fn($input, json, { ONLY_DIALOGS: 'true', TZ: 'Europe/Moscow', ...env });
}

const parsePoll = code(poll, 'Разобрать updates');
const parseHook = code(hook, 'Разобрать апдейт');
const menu = code(core, 'Меню');
const echo = code(core, 'Эхо-ответ');

const dialogMsg = (mid, text) => ({
  update_type: 'message_created', timestamp: 1,
  message: {
    recipient: { chat_type: 'dialog', chat_id: 42, user_id: 7 },
    sender: { user_id: 7, first_name: 'Никита', username: 'nk' },
    body: { mid, text },
  },
});

// --- 1. polling: групповые чаты и боты отбрасываются -----------------------
const out = run(parsePoll, {
  items: [{
    marker: 777,
    updates: [
      { update_type: 'message_created', message: { recipient: { chat_type: 'chat', chat_id: -690878 }, sender: { user_id: 5, name: 'Житель' }, body: { mid: 'm1', text: 'привет' } } },
      dialogMsg('m2', '/start'),
      { update_type: 'message_created', message: { recipient: { chat_type: 'dialog', chat_id: 43 }, sender: { user_id: 9, name: 'Бот', is_bot: true }, body: { mid: 'm3', text: 'спам' } } },
    ],
  }],
});
assert.equal(out.length, 1, 'должен остаться только личный диалог от человека');
assert.deepEqual(
  { kind: out[0].json.kind, chat_id: out[0].json.chat_id, name: out[0].json.name, text: out[0].json.text },
  { kind: 'message', chat_id: 42, name: 'Никита', text: '/start' },
);
assert.equal(out[0].json.dedup_key, 'msg:m2', 'ключ идемпотентности строится из mid');

// --- 2. ONLY_DIALOGS=false выпускает бота в группы -------------------------
const grp = run(parsePoll, {
  items: [{ marker: 1, updates: [{ update_type: 'message_created', message: { recipient: { chat_type: 'chat', chat_id: -1 }, sender: { user_id: 5, name: 'Ж' }, body: { mid: 'g1', text: 'ok' } } }] }],
  env: { ONLY_DIALOGS: 'false' },
});
assert.equal(grp.length, 1, 'ONLY_DIALOGS=false должен пропускать групповые чаты');

// --- 3. webhook разбирает то же событие в ту же форму ----------------------
const viaHook = run(parseHook, { items: [{ body: dialogMsg('m2', '/start') }] });
assert.deepEqual(viaHook[0].json, out[0].json, 'polling и webhook обязаны давать одну структуру');

// --- 4. callback: dedup_key из callback_id --------------------------------
const cb = run(parseHook, {
  items: [{ body: { update_type: 'message_callback', timestamp: 2,
    callback: { callback_id: 'cb1', payload: 'catalog', user: { user_id: 7, first_name: 'Никита' } },
    message: { recipient: { chat_type: 'dialog', chat_id: 42, user_id: 7 } } } }],
});
assert.equal(cb[0].json.kind, 'callback');
assert.equal(cb[0].json.dedup_key, 'cb:cb1');

// --- 5. bot_started трактуется как /start ---------------------------------
const started = run(parseHook, {
  items: [{ body: { update_type: 'bot_started', timestamp: 3,
    message: { recipient: { chat_type: 'dialog', chat_id: 42, user_id: 7 } },
    user: { user_id: 7, first_name: 'Н' } } }],
});
assert.equal(started[0].json.text, '/start');

// --- 6. сообщение -> POST /messages с клавиатурой --------------------------
const main = run(menu, { json: { kind: 'message', chat_id: 42, name: 'Никита', text: '/start' } })[0].json;
assert.equal(main.api_path, 'messages');
assert.equal(main.api_query.chat_id, '42');
assert.ok(main.body.text.includes('Никита'), 'имя подставляется вместо {name}');
const kb = main.body.attachments.find((a) => a.type === 'inline_keyboard');
assert.ok(kb && kb.payload.buttons.length >= 2);
for (const row of kb.payload.buttons) {
  for (const b of row) {
    assert.ok(b.text, 'у каждой кнопки обязателен text');
    if (b.type === 'callback') assert.ok(b.payload, 'у callback-кнопки обязателен payload');
    if (b.type === 'link') assert.ok(b.url, 'у link-кнопки обязателен url');
  }
}

// --- 7. callback -> POST /answers, сообщение меняется на месте -------------
const ans = run(menu, { json: { kind: 'callback', chat_id: 42, name: 'Н', payload: 'catalog', callback_id: 'cb1' } })[0].json;
assert.equal(ans.api_path, 'answers');
assert.equal(ans.api_query.callback_id, 'cb1');
assert.ok(ans.body.message.attachments[0].payload.buttons.flat().some((b) => b.payload === 'main'),
  'в подменю должна быть кнопка «Назад»');

// --- 8. динамический экран и фолбэк ---------------------------------------
assert.ok(run(menu, { json: { kind: 'callback', chat_id: 42, name: 'Н', payload: 'item:b', callback_id: 'c' } })[0].json.body.message.text.includes('B'));
assert.ok(run(menu, { json: { kind: 'callback', chat_id: 42, name: 'Н', payload: 'нет-такого', callback_id: 'c' } })[0].json.body.message.text.length > 0,
  'неизвестный payload должен падать в главное меню, а не ронять сценарий');

// --- 9. ветка «эхо» -------------------------------------------------------
const e = run(echo, { json: { kind: 'message', chat_id: 42, name: 'Н', text: 'эхо тест 123' } })[0].json;
assert.ok(e.body.text.includes('тест 123') && !e.body.text.includes('эхо тест'), 'префикс «эхо » срезается');

// --- 10. структурные инварианты сценариев ---------------------------------
// Параметры Postgres обязаны передаваться массивом: строка через запятую
// разъезжается на тексте пользователя с запятой.
for (const n of core.nodes.filter((x) => x.type === 'n8n-nodes-base.postgres')) {
  const qr = n.parameters.options?.queryReplacement;
  if (qr !== undefined) assert.match(qr, /^=\{\{\s*\[/, `${n.name}: queryReplacement должен быть массивом`);
}
// Дубль обязан обрываться до отправки ответа.
assert.deepEqual(core.connections['Новое событие?'].main[1], [],
  'ложная ветка «Новое событие?» должна быть пустой');
// Ошибка вызова движка не должна маскироваться под успех.
for (const wf of [poll, hook]) {
  assert.equal(nodeOf(wf, 'Передать в движок').onError, undefined,
    `${wf.name}: ошибка вызова движка не должна подавляться`);
}
// Оба источника обязаны звать один и тот же движок.
for (const wf of [poll, hook]) {
  assert.equal(nodeOf(wf, 'Передать в движок').parameters.workflowId.value, core.id);
}
// Опрос подтверждает marker даже при нуле апдейтов, иначе очередь MAX растёт.
assert.ok(poll.connections['GET /updates'].main[0].some((c) => c.node === 'Сохранить marker'),
  '«Сохранить marker» должен висеть прямо на GET /updates, а не за разбором');

console.log('OK: 10 групп проверок пройдено');
