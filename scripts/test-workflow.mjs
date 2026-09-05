// Проверка логики сценариев: берёт настоящий код из workflows/*.json и контент
// из db/seed/bot_content.json, прогоняет на фикстурах. Дублирования нет —
// тестируется то, что уедет в n8n и в базу.
// Запуск: make test
import { readFileSync } from 'node:fs';
import assert from 'node:assert/strict';

const load = (f) => JSON.parse(readFileSync(new URL(`../${f}`, import.meta.url), 'utf8'));
const core = load('workflows/max-bot-core.json');
const send = load('workflows/max-bot-send.json');
const admin = load('workflows/max-bot-admin.json');
const poll = load('workflows/max-bot-polling.json');
const hook = load('workflows/max-bot-webhook.json');
const seed = load('db/seed/bot_content.json');

const nodeOf = (wf, name) => {
  const n = wf.nodes.find((x) => x.name === name);
  assert.ok(n, `в «${wf.name}» нет ноды «${name}»`);
  return n;
};
const code = (wf, name) => nodeOf(wf, name).parameters.jsCode;
const isCode = (n) => n.type === 'n8n-nodes-base.code';

const ENV = { ONLY_DIALOGS: 'true', TZ: 'Europe/Moscow', ADMIN_IDS: '' };

// Мини-песочница вместо рантайма n8n.
function run(js, { json, items, prev = {}, env = {} } = {}) {
  const all = items ?? [json];
  const $input = { first: () => ({ json: all[0] }), all: () => all.map((j) => ({ json: j })) };
  // $('Имя ноды') — доступ к выходу предыдущей ноды.
  const $ = (name) => {
    assert.ok(name in prev, `сценарий обращается к ноде «${name}», которой нет в фикстуре`);
    return { first: () => ({ json: prev[name] }), item: { json: prev[name] } };
  };
  return new Function('$input', '$json', '$env', '$', js)($input, json, { ...ENV, ...env }, $);
}

const parsePoll = code(poll, 'Разобрать updates');
const parseHook = code(hook, 'Разобрать апдейт');
const brain = code(core, 'Сценарий');
const orderReply = code(core, 'Подтверждение и админам');
const ratesReply = code(core, 'Показать курс');
const ordersReply = code(core, 'Показать заказы');

// Контент в том виде, в каком его отдаёт нода «Состояние и контент».
const SCREENS = Object.fromEntries(seed.screens.map((s) => [s.key, { text: s.text, buttons: s.buttons }]));
const PRODUCTS = [...seed.products].sort((a, b) => a.sort - b.sort).map((p) => ({ active: true, ...p }));
const content = { screens: SCREENS, products: PRODUCTS };

const dialogMsg = (mid, text, extra = {}) => ({
  update_type: 'message_created', timestamp: 1,
  message: {
    recipient: { chat_type: 'dialog', chat_id: 42, user_id: 7 },
    sender: { user_id: 7, first_name: 'Никита', username: 'nk' },
    body: { mid, text, ...extra },
  },
});

const ev = (over = {}) => ({
  kind: 'message', update_type: 'message_created', chat_id: 42, user_id: 7,
  name: 'Никита', username: 'nk', text: '', payload: null, callback_id: null,
  contact_phone: null, geo: null, ...over,
});
const cbEv = (payload) => ev({ kind: 'callback', payload, callback_id: 'cb1', text: '' });

// думаем сценарием: state — строка dialog_state, контент — из seed
const think = (event, state = { screen: 'main', step: null, data: {} }, extra = {}) =>
  run(brain, { json: { ...state, ...content, ...extra }, prev: { 'Вернуть событие': event } })[0].json;

const buttons = (r) => (r.buttons ?? []).flat();
// ru-RU разделяет тысячи неразрывным пробелом (U+00A0) — в проверках сводим к обычному.
const textOf = (r) => r.text.replace(/\u00a0/g, ' ');
const withContent = (event) => ({ 'Вернуть событие': event, 'Состояние и контент': content });

// ─── 1. Нормализация ────────────────────────────────────────────────────────
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
assert.equal(out[0].json.dedup_key, 'msg:m2');
assert.equal(out[0].json.text, '/start');

assert.equal(run(parsePoll, {
  items: [{ marker: 1, updates: [{ update_type: 'message_created', message: { recipient: { chat_type: 'chat', chat_id: -1 }, sender: { user_id: 5, name: 'Ж' }, body: { mid: 'g1', text: 'ok' } } }] }],
  env: { ONLY_DIALOGS: 'false' },
}).length, 1, 'ONLY_DIALOGS=false должен пропускать групповые чаты');

assert.deepEqual(run(parseHook, { items: [{ body: dialogMsg('m2', '/start') }] })[0].json, out[0].json,
  'polling и webhook обязаны давать одну структуру');

// Телефон из вложения contact (кнопка request_contact).
const withContact = run(parseHook, { items: [{ body: dialogMsg('m4', '', {
  attachments: [{ type: 'contact', payload: { vcf_info: 'BEGIN:VCARD\nTEL;TYPE=CELL:+7 (900) 123-45-67\nEND:VCARD' } }] }) }] });
assert.equal(withContact[0].json.contact_phone, '+79001234567', 'телефон должен доставаться из vCard');

// Геопозиция из вложения location.
const withGeo = run(parseHook, { items: [{ body: dialogMsg('m5', '', {
  attachments: [{ type: 'location', payload: { latitude: 48.7, longitude: 44.5 } }] }) }] });
assert.deepEqual(withGeo[0].json.geo, { lat: 48.7, lon: 44.5 });

assert.equal(run(parseHook, { items: [{ body: { update_type: 'bot_started', timestamp: 3,
  message: { recipient: { chat_type: 'dialog', chat_id: 42, user_id: 7 } }, user: { user_id: 7, first_name: 'Н' } } }] })[0].json.text,
  '/start', 'bot_started трактуется как /start');

// ─── 2. Экраны из bot_screens: меню, компания, каталог, карточка ───────────
const main = think(ev({ text: '/start' }));
assert.equal(main.action, 'reply');
assert.equal(main.reply.callback_id, null, 'сообщение -> новое сообщение, не правка');
assert.equal(main.reply.chat_id, 42);
assert.ok(textOf(main.reply).includes('Никита'), '{name} подставляется в приветствие');
assert.ok(!textOf(main.reply).includes('{name}'));

const about = think(cbEv('about'));
assert.equal(about.reply.callback_id, 'cb1', 'нажатие кнопки меняет сообщение на месте');
assert.ok(textOf(about.reply).includes('Тест Компания'));
const ab = buttons(about.reply);
assert.ok(ab.some((b) => b.type === 'link' && b.url), 'на экране компании нужна кнопка-ссылка');
const clip = ab.find((b) => b.type === 'clipboard');
assert.ok(clip && /^\+\d{10,}$/.test(clip.payload), 'кнопка clipboard должна нести телефон');
assert.ok(ab.some((b) => b.payload === 'main'), 'нужна кнопка «Назад»');

const cat = think(cbEv('catalog'));
const catBtns = buttons(cat.reply).filter((b) => String(b.payload).startsWith('item:'));
assert.equal(catBtns.length, PRODUCTS.length, 'в каталоге по кнопке на каждый товар');
assert.equal(catBtns[0].payload, `item:${PRODUCTS[0].id}`, 'порядок кнопок — по sort');
assert.ok(catBtns[0].text.includes(PRODUCTS[0].title) && catBtns[0].text.includes('₽'));
// Снятый с продажи товар в каталог не попадает.
const catInactive = think(cbEv('catalog'), undefined, { products: PRODUCTS.map((p, i) => (i ? p : { ...p, active: false })) });
assert.equal(buttons(catInactive.reply).filter((b) => String(b.payload).startsWith('item:')).length, PRODUCTS.length - 1);

const item = think(cbEv('item:a'));
assert.ok(textOf(item.reply).includes('Кофемашина') && textOf(item.reply).includes('24 900'), 'карточка: название и цена из bot_products');
assert.ok(buttons(item.reply).some((b) => b.payload === 'order:a'), 'в карточке нужна кнопка «Заказать»');
assert.ok(buttons(item.reply).some((b) => b.payload === 'catalog'), 'и возврат в каталог');
assert.equal(buttons(think(cbEv('item:нет')).reply).some((b) => b.payload === 'item:a'), true, 'неизвестный товар -> каталог');

// Новый экран — строка в таблице, код не меняется.
const delivery = think(cbEv('delivery'), undefined, { screens: { ...SCREENS,
  delivery: { text: '🚚 Доставка для {name}', buttons: [[{ type: 'callback', text: 'Назад', payload: 'main' }]] } } });
assert.equal(textOf(delivery.reply), '🚚 Доставка для Никита', 'экран из bot_screens показывается по своему ключу');
assert.ok(textOf(think(cbEv('main'), undefined, { screens: {} }).reply).includes('не найден'),
  'пустая таблица экранов не роняет сценарий');

// ─── 3. Форма заказа: товар -> количество -> телефон ───────────────────────
const step1 = think(cbEv('order:a'));
assert.deepEqual({ screen: step1.state.screen, step: step1.state.step }, { screen: 'order', step: 'qty' });
assert.equal(step1.state.data.product_id, 'a', 'id товара запоминается автоматически');
assert.ok(buttons(step1.reply).some((b) => b.payload === 'qty:2'), 'пресеты количества — из шаблона order_qty');

const inQty = { screen: 'order', step: 'qty', data: { product_id: 'a' } };
// количество кнопкой
const step2 = think(cbEv('qty:2'), inQty);
assert.equal(step2.state.step, 'phone');
assert.equal(step2.state.data.qty, 2);
assert.ok(textOf(step2.reply).includes('49 800'), '{total} = цена × количество');
// количество текстом
assert.equal(think(ev({ text: '3' }), inQty).state.data.qty, 3, 'количество можно ввести текстом');
// мусор не двигает форму вперёд
const bad = think(ev({ text: 'много' }), inQty);
assert.equal(bad.state.step, 'qty', 'некорректное количество оставляет на том же шаге');
assert.ok(textOf(bad.reply).includes('от 1 до 99'));

const inPhone = { screen: 'order', step: 'phone', data: { product_id: 'a', qty: 2 } };
// телефон кнопкой «отправить контакт»
const done = think(ev({ contact_phone: '+79001234567' }), inPhone);
assert.equal(done.action, 'order');
assert.equal(done.state, null, 'после оформления форма закрывается');
assert.deepEqual(
  { p: done.order.product_id, q: done.order.qty, ph: done.order.phone, total: done.order.total_rub },
  { p: 'a', q: 2, ph: '+79001234567', total: done.order.price_rub * 2 },
);
// телефон текстом
assert.equal(think(ev({ text: '8 900 123-45-67' }), inPhone).order.phone, '89001234567');
// мусор вместо телефона
assert.equal(think(ev({ text: 'позвоните мне' }), inPhone).state.step, 'phone');
// отмена
const cancelled = think(cbEv('cancel'), inPhone);
assert.equal(cancelled.state, null, 'отмена очищает состояние');

// Пока идёт форма, «3» — это количество, а не команда. Но кнопки навигации
// обязаны работать всегда, иначе из формы не выйти.
assert.equal(think(cbEv('main'), inQty).action, 'reply');
assert.ok(think(cbEv('catalog'), inQty).reply.text.includes('Каталог'));

// ─── 4. Прочие сценарии ────────────────────────────────────────────────────
assert.equal(think(cbEv('rates')).action, 'rates', 'курс валют уходит во внешний API');
assert.equal(think(cbEv('myorders')).action, 'myorders');
assert.ok(textOf(think(ev({ text: '/whoami' })).reply).includes('`7`'), '/whoami показывает user_id');
assert.ok(textOf(think(ev({ text: 'эхо привет' })).reply).includes('привет'));
assert.ok(textOf(think(ev({ geo: { lat: 48.7, lon: 44.5 } })).reply).includes('48.7'),
  'геопозиция подтверждается координатами');
assert.equal(think(cbEv('нет-такого-экрана')).action, 'reply',
  'неизвестный payload не должен ронять сценарий');

// ─── 5. Сборка ответов после обращения к БД и API ──────────────────────────
const ordItems = run(orderReply, {
  json: { id: 77 },
  prev: { ...withContent(ev({})),
    'Сценарий': { order: { product_title: 'Кофемашина «Утро»', qty: 2, total_rub: 49800, phone: '+79001234567' } } },
  env: { ADMIN_IDS: '111, 222' },
});
assert.equal(ordItems.length, 3, 'подтверждение клиенту + два уведомления админам');
assert.ok(ordItems[0].json.text.includes('№77') && textOf(ordItems[0].json).includes('49 800'));
assert.equal(ordItems[0].json.chat_id, 42);
assert.deepEqual(ordItems.slice(1).map((i) => [i.json.user_id, i.json.chat_id]), [['111', null], ['222', null]],
  'админам — по user_id, без chat_id');
assert.ok(ordItems[1].json.text.includes('@nk'), 'в уведомлении админу — клиент');
assert.equal(run(orderReply, { json: { id: 1 }, prev: { ...withContent(ev({})),
  'Сценарий': { order: { product_title: 'x', qty: 1, total_rub: 1, phone: '+7' } } } }).length,
  1, 'пустой ADMIN_IDS не должен ломать оформление заказа');

const rates = run(ratesReply, {
  json: { Date: '2026-09-05T11:30:00+03:00', Valute: {
    USD: { Name: 'Доллар США', Value: 90.5, Previous: 91 },
    EUR: { Name: 'Евро', Value: 99.1, Previous: 98 },
    CNY: { Name: 'Юань', Value: 12.3, Previous: 12.2 } } },
  prev: withContent(cbEv('rates')),
})[0].json;
assert.equal(rates.callback_id, 'cb1');
assert.ok(rates.text.includes('90.50') && rates.text.includes('05.09.2026'));
assert.ok(buttons(rates).some((b) => b.payload === 'rates'), 'кнопка «Обновить» из шаблона rates');

// ЦБ отдаёт JSON под расширением .js: если нода вернёт тело строкой,
// экран курса всё равно обязан собраться.
const ratesRaw = run(ratesReply, {
  json: { data: JSON.stringify({ Date: '2026-09-05T11:30:00+03:00', Valute: {
    USD: { Name: 'Доллар США', Value: 90.5, Previous: 91 } } }) },
  prev: withContent(cbEv('rates')),
})[0].json;
assert.ok(ratesRaw.text.includes('90.50'), 'курс должен разбираться и из строки');

const empty = run(ordersReply, { items: [{ success: true }], prev: withContent(cbEv('myorders')) })[0].json;
assert.ok(empty.text.includes('пока нет'), 'пустой список заказов не должен падать');
const some = run(ordersReply, {
  items: [{ id: 5, product_title: 'Термос', qty: 1, total_rub: 1890, status: 'new', created_at: '2026-09-05T10:00:00Z' }],
  prev: withContent(cbEv('myorders')),
})[0].json;
assert.ok(some.text.includes('№5') && some.text.includes('Термос'));

// ─── 6. Контент: seed согласован с кодом ───────────────────────────────────
const KNOWN_VARS = new Set(['name', 'user_id', 'chat_id', 'id', 'title', 'short', 'description', 'price',
  'qty', 'total', 'phone', 'order_id', 'client', 'lat', 'lon', 'echo', 'rates_date', 'rates_lines', 'orders']);
const DYNAMIC = /^(item|order|qty):/;
for (const s of seed.screens) {
  for (const m of JSON.stringify(s).matchAll(/\{(\w+)\}/g)) {
    assert.ok(KNOWN_VARS.has(m[1]), `экран «${s.key}»: плейсхолдер {${m[1]}} сценарий не подставляет`);
  }
  assert.ok(Array.isArray(s.buttons) && s.buttons.every(Array.isArray), `экран «${s.key}»: кнопки — массив рядов`);
  for (const b of s.buttons.flat()) {
    if (b.type !== 'callback' || DYNAMIC.test(b.payload)) continue;
    assert.ok(['rates', 'myorders', 'cancel'].includes(b.payload) || SCREENS[b.payload],
      `экран «${s.key}»: кнопка ведёт на несуществующий экран «${b.payload}»`);
  }
}
for (const need of ['main', 'catalog', 'item', 'order_qty', 'order_qty_bad', 'order_phone', 'order_phone_bad',
  'order_done', 'order_admin', 'cancel', 'rates', 'myorders', 'myorders_empty', 'whoami', 'geo', 'echo']) {
  assert.ok(SCREENS[need], `в seed нет обязательного экрана «${need}»`);
}
assert.ok(PRODUCTS.every((p) => /^[a-z0-9_-]+$/.test(p.id)), 'id товара попадает в payload — только латиница');

// ─── 7. Структурные инварианты ─────────────────────────────────────────────
// Параметры Postgres обязаны передаваться массивом: строка через запятую
// разъезжается на тексте пользователя с запятой.
for (const wf of [core, send, admin]) {
  for (const n of wf.nodes.filter((x) => x.type === 'n8n-nodes-base.postgres')) {
    const qr = n.parameters.options?.queryReplacement;
    if (qr !== undefined) assert.match(qr, /^=\{\{\s*\[/, `${wf.name} / ${n.name}: queryReplacement должен быть массивом`);
  }
}
assert.deepEqual(core.connections['Новое событие?'].main[1], [],
  'ложная ветка «Новое событие?» должна быть пустой — иначе бот ответит на дубль');
for (const wf of [poll, hook]) {
  assert.equal(nodeOf(wf, 'Передать в движок').onError, undefined,
    `${wf.name}: ошибка вызова движка не должна подавляться`);
  assert.equal(nodeOf(wf, 'Передать в движок').parameters.workflowId.value, core.id);
}
assert.ok(poll.connections['GET /updates'].main[0].some((c) => c.node === 'Сохранить marker'),
  '«Сохранить marker» должен висеть прямо на GET /updates, а не за разбором');
// Все четыре ветки Switch обязаны сходиться на одной отправке.
for (const b of core.connections['Что дальше?'].main) assert.equal(b.length, 1);
const reaches = (wf, from, target, seen = new Set()) => {
  if (from === target) return true;
  if (seen.has(from)) return false;
  seen.add(from);
  return (wf.connections[from]?.main ?? []).flat().some((c) => reaches(wf, c.node, target, seen));
};
assert.ok(core.connections['Что дальше?'].main.every((b) => reaches(core, b[0].node, 'Отправить в MAX')),
  'каждая ветка «Что дальше?» должна доходить до «Отправить в MAX»');
assert.equal(nodeOf(core, 'Отправить в MAX').parameters.workflowId.value, send.id);
assert.equal(nodeOf(core, 'Выбрать заказы').alwaysOutputData, true,
  'пустой список заказов должен доходить до сборки ответа');
// Отправка и админка — переиспользуемые элементы без единой строки кода.
assert.equal(send.nodes.filter(isCode).length, 0, 'в «Отправить в MAX» не должно быть Code-нод');
assert.equal(admin.nodes.filter(isCode).length, 0, 'в админке не должно быть Code-нод');
assert.equal(nodeOf(send, 'POST в MAX API').onError, 'continueErrorOutput');
assert.deepEqual(send.connections['POST в MAX API'].main[1].map((c) => c.node), ['Записать ошибку отправки'],
  'ошибка MAX API должна уходить в bot_send_failures');
for (const n of admin.nodes.filter((x) => x.type === 'n8n-nodes-base.formTrigger')) {
  assert.equal(n.parameters.authentication, 'basicAuth', `${n.name}: форма торчит наружу — только за Basic Auth`);
}

console.log('OK: 7 групп проверок пройдено');
