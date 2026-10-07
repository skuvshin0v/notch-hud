#!/usr/bin/env python3
"""Plays fake Claude Code sessions into ~/.claude/notch-hud so the widget can be tried by hand.

Two sessions: progress with tasks, a question, a permission ask, a finished turn
with a reply box, a multi-question ask. Every ask waits for the real answer from
the widget and logs it. Usage: python3 scripts/demo.py

`python3 scripts/demo.py states` plays the compact island's states instead: each
step prints what the island should show, to compare by eye.
"""
import json
import os
import sys
import threading
import time

W = os.path.expanduser("~/.claude/notch-hud")
SESSIONS = {}
LOCK = threading.Lock()
STOP = False


def now_ms():
    return int(time.time() * 1000)


def log(*args):
    print(time.strftime("%H:%M:%S"), *args, flush=True)


def write(sid):
    if STOP:
        return  # the run is over: never bring back a card it just removed
    with LOCK:
        s = SESSIONS[sid]
        s["updatedAt"] = now_ms()
        path = f"{W}/sessions/{sid}.json"
        tmp = path + ".tmp"
        with open(tmp, "w") as f:
            json.dump(s, f, ensure_ascii=False)
        os.replace(tmp, path)


def update(sid, **kw):
    with LOCK:
        SESSIONS[sid].update(kw)
    write(sid)


def heartbeat():
    while not STOP:
        for sid in list(SESSIONS):
            write(sid)
        time.sleep(3)


def new_session(sid, project, title):
    SESSIONS[sid] = {
        "id": sid, "cwd": f"/tmp/{project}", "project": project, "host": "", "hostName": "demo",
        "pid": 0, "title": title, "status": "working", "turnStartedAt": now_ms(),
        "activity": "Thinking…", "tasks": [], "lastText": "", "pending": None, "turns": 1, "updatedAt": 0,
    }
    write(sid)


def ask(sid, pending, timeout=180):
    """Puts an ask on the card and waits for the widget's answer file."""
    update(sid, pending=pending, status="waiting")
    path = f"{W}/answers/{sid}/{pending['id']}.json"
    os.makedirs(os.path.dirname(path), exist_ok=True)
    log(f"[{sid}] ждёт ответа: {pending['kind']}")
    deadline = time.time() + timeout
    answer = None
    while time.time() < deadline:
        if os.path.exists(path):
            time.sleep(0.1)
            with open(path) as f:
                answer = json.load(f)
            os.remove(path)
            break
        time.sleep(0.3)
    log(f"[{sid}] ответ:", json.dumps(answer, ensure_ascii=False) if answer else "нет (таймаут)")
    update(sid, pending=None, status="working")
    return answer


def wait_inbox(sid, timeout=90):
    path = f"{W}/inbox/{sid}.json"
    deadline = time.time() + timeout
    while time.time() < deadline:
        if os.path.exists(path):
            time.sleep(0.1)
            with open(path) as f:
                text = json.load(f).get("text", "")
            os.remove(path)
            log(f"[{sid}] промпт из виджета: {text!r}")
            return text
        time.sleep(0.3)
    log(f"[{sid}] промпт из виджета не пришёл")
    return None


def tasks(*pairs):
    return [{"id": str(i), "subject": s, "status": st} for i, (s, st) in enumerate(pairs)]


def stop_previous_run():
    """Only one demo at a time: two would write the same cards with different states."""
    pidfile = f"{W}/demo.pid"
    try:
        os.kill(int(open(pidfile).read()), 15)
        time.sleep(0.5)
    except (OSError, ValueError):
        pass
    with open(pidfile, "w") as f:
        f.write(str(os.getpid()))


def main():
    global STOP
    stop_previous_run()
    for d in ("sessions", "answers", "inbox"):
        os.makedirs(f"{W}/{d}", exist_ok=True)
    A, B = "demo-api", "demo-landing"
    new_session(A, "api-server", "Добавь OAuth-авторизацию")
    new_session(B, "landing", "Сверстай секцию тарифов")
    threading.Thread(target=heartbeat, daemon=True).start()
    log("старт: 2 сессии работают")

    plan = ["Схема БД", "OAuth callback", "Сессии и куки", "Тесты"]
    acts = [("Read schema.prisma", "Read"), ("Grep \"User\"", "Grep"), ("Edit schema.prisma", "Edit"),
            ("Run migrations", "Bash"), ("Fetch prisma docs", "WebFetch"), ("Agent: review schema", "Agent")]
    for i, (act, tool) in enumerate(acts):
        update(A, activity=act, tool=tool, tasks=tasks(*[(p, "completed" if j < i // 2 else "in_progress" if j == i // 2 else "pending") for j, p in enumerate(plan)]))
        update(B, activity=act, tool="")
        time.sleep(3)

    # 1. Single-choice question
    ask(A, {"id": "q-provider", "kind": "question", "questions": [{
        "question": "Какой **OAuth-провайдер** подключить первым?", "header": "Провайдер", "multiSelect": False,
        "options": [{"label": "Google", "description": "самый частый у пользователей"},
                    {"label": "GitHub", "description": "если аудитория — разработчики"},
                    {"label": "Apple", "description": "обязателен для iOS-приложения"}]}]})
    update(A, activity="Edit auth/callback.ts", tasks=tasks((plan[0], "completed"), (plan[1], "in_progress"), (plan[2], "pending"), (plan[3], "pending")))
    time.sleep(3)

    # 2. Permission ask
    ask(B, {"id": "perm-npm", "kind": "permission", "tool": "Bash", "summary": "Установить зависимости",
            "detail": "npm install @radix-ui/react-tabs clsx", "canAlways": True})
    update(B, activity="npm install")
    time.sleep(4)

    # 3. Finished turn: flash in the island, reply box on the card
    update(B, status="done", activity="", turns=2, lastText=(
        "## Секция тарифов готова\n\n"
        "Сделал **3 тарифа** с переключателем *месяц / год*:\n\n"
        "- `Free` — базовые функции\n- `Pro` — $12/мес\n- `Team` — $49/мес\n\n"
        "```sh\nnpm run dev\n```\n\n> Скидка за год — 20%, вынес в `PRICING_DISCOUNT`.\n\n"
        "Ссылки: [документация Stripe](https://docs.stripe.com/payments) и голая https://github.com/anthropics/claude-code"))
    log(f"[{B}] готово — напиши что-нибудь в поле ответа этой карточки")
    for i, act in enumerate(["Edit session.ts", "Run tests"]):
        update(A, activity=act, tasks=tasks((plan[0], "completed"), (plan[1], "completed"), (plan[2], "completed" if i else "in_progress"), (plan[3], "in_progress" if i else "pending")))
        time.sleep(3)
    reply = wait_inbox(B, timeout=60)
    if reply:
        update(B, status="working", activity="Thinking…", title=reply[:80], turnStartedAt=now_ms())
        time.sleep(4)
        update(B, status="done", activity="", turns=3, lastText=f"Принял: «{reply}». Это демо, тут ответ заканчивается ✓")

    # 4. Two questions, one multi-select
    ask(A, {"id": "q-multi", "kind": "question", "questions": [
        {"question": "Какие тесты добавить?", "header": "Тесты", "multiSelect": True,
         "options": [{"label": "Unit"}, {"label": "Интеграционные"}, {"label": "E2E", "description": "Playwright"}]},
        {"question": "Где хранить сессии?", "header": "Хранилище", "multiSelect": False,
         "options": [{"label": "Redis"}, {"label": "Postgres"}]}]})
    update(A, status="done", activity="", turns=2, tasks=tasks(*[(p, "completed") for p in plan]),
           lastText="**OAuth готов**: провайдер подключён, сессии в хранилище, тесты зелёные ✓")
    log("сценарий закончен; карточки исчезнут через 20 секунд")
    time.sleep(20)
    STOP = True
    for sid in SESSIONS:
        try:
            os.remove(f"{W}/sessions/{sid}.json")
        except FileNotFoundError:
            pass
    log("конец")


TABLE = (
    "## Итог\n\n"
    "| Провайдер | Статус | Заметка |\n"
    "|---|:---:|---|\n"
    "| Google | ✓ | подключён, ключи в `.env` |\n"
    "| GitHub | ✓ | нужен callback URL |\n"
    "| Apple | — | отложили до iOS-версии |\n\n"
    "Подробнее: https://developer.apple.com/sign-in-with-apple/"
)


FEEDBACK = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "demo-feedback.md")
CURRENT = {"n": 0, "step": "старт"}


INTERACTIVE = sys.stdin.isatty()


def note(text):
    with open(FEEDBACK, "a") as f:
        f.write(f"- [шаг {CURRENT['n']}: {CURRENT['step']}] {text}\n")
    log(f"  ✍︎ записал к шагу {CURRENT['n']}")


def step(expect, seconds):
    """One look of the island. In a terminal it waits for you: an empty Enter goes on, a line of
    text is a note on this step. Piped (no terminal), it waits `seconds`."""
    CURRENT["n"] += 1
    CURRENT["step"] = expect.split(":")[0]
    log(f"[{CURRENT['n']}] ЖДИ В ЧЁЛКЕ → {expect}")
    if not INTERACTIVE:
        time.sleep(seconds)
        return
    while True:
        line = sys.stdin.readline()
        if not line or not line.strip():
            return
        note(line.strip())


def feedback_reader():
    """Any line typed in the demo's terminal is a note on the current step, saved to demo-feedback.md."""
    while not STOP:
        try:
            line = sys.stdin.readline()
        except Exception:
            return
        if not line:
            return
        if line.strip():
            note(line.strip())


def states():
    """Walks the island through every look it has, one step at a time; each step prints what to see."""
    global STOP
    for d in ("sessions", "answers", "inbox"):
        os.makedirs(f"{W}/{d}", exist_ok=True)
    limits_path = f"{W}/limits.json"
    saved_limits = open(limits_path).read() if os.path.exists(limits_path) else None

    def set_limit(percent):
        body = {"updatedAt": now_ms(), "limits": [
            {"kind": "five_hour", "percentUsed": percent, "resetsAt": "2030-01-01T00:00:00.000Z"},
            {"kind": "seven_day", "percentUsed": 40, "resetsAt": "2030-01-05T00:00:00.000Z"}]}
        with open(limits_path, "w") as f:
            json.dump(body, f)

    def restore_limits():
        if saved_limits is not None:
            with open(limits_path, "w") as f:
                f.write(saved_limits)

    A, B, G = "demo-alpha", "demo-beta", "demo-gamma"
    threading.Thread(target=heartbeat, daemon=True).start()
    try:
        log("Сценарий для свёрнутой чёлки: не раскрывай её, пока шаг не попросит. Другие чаты лучше не трогать.")
        step("ТИХИЙ РЕЖИМ (если 30 с ничего не происходило): слева тусклая ✳︎, справа маленькая точка", 5)

        new_session(A, "alpha", "Сделай авторизацию через OAuth")
        update(A, tool="", activity="Thinking…",
               history=[{"from": "you", "prompt": "Сделай авторизацию через OAuth", "answer": ""}])
        step("ДУМАЕТ: слева ✦ искра (пульсирует), справа «…» бегущие точки", 5)

        for tool, act, what in [("Read", "Read schema.prisma", "📄 документ"), ("Grep", "Grep \"User\"", "🔍 лупа"),
                                ("Edit", "Edit auth.ts", "✎ карандаш"), ("Bash", "npm test", "терминал"),
                                ("WebFetch", "Fetch docs", "🌐 глобус"), ("Agent", "Agent: review", "👥 два человечка"),
                                ("mcp__github__create_issue", "github · create_issue", "🧩 пазл (MCP)")]:
            update(A, tool=tool, activity=act)
            step(f"ИНСТРУМЕНТ: слева {what}, справа «…»", 3)

        plan = ["Схема БД", "OAuth callback", "Сессии", "Тесты"]
        for k in range(4):
            update(A, tool="Edit", activity="Edit auth.ts",
                   tasks=tasks(*[(p, "completed" if j < k else "in_progress" if j == k else "pending") for j, p in enumerate(plan)]))
            step(f"ЗАДАЧИ {k}/4: справа кольцо заполняется на {k}/4", 3)

        update(A, tool="Agent", activity="Agent: review", agents=[
            {"id": "a1", "description": "Проверить схему", "type": "Explore", "status": "running", "activity": "Read schema.prisma"},
            {"id": "a2", "description": "Написать тесты", "type": "general-purpose", "status": "running", "activity": "Edit auth.test.ts"}])
        step("АГЕНТЫ: раскрой чёлку и открой alpha — блок «Работают агенты: 2» с их задачами и действиями. Потом сверни", 14)
        update(A, agents=[])

        new_session(B, "beta", "Почини сборку")
        update(B, tool="Bash", activity="npm run build")
        time.sleep(2)
        update(B, status="done", tool="", activity="", turns=2, lastText="Сборка зелёная ✓",
               history=[{"from": "you", "prompt": "Почини сборку", "answer": "Сборка зелёная ✓"}])
        step("ЧАТ ЗАКОНЧИЛ, ПОКА ДРУГОЙ РАБОТАЕТ: 3 с слева ✓ подпрыгивает, справа точка; потом иконка alpha с ЗЕЛЁНОЙ точкой в углу", 8)
        step("раскрой чёлку (у beta зелёная точка в строке) и сверни — зелёная точка в углу пропадёт", 12)

        set_limit(82)
        step("ЛИМИТ 80%: 3 с слева 📈 оранжевый, потом ОРАНЖЕВАЯ точка в верхнем углу иконки", 7)
        set_limit(96)
        step("ЛИМИТ 95%: 3 с 📈 красный, потом точка в углу КРАСНАЯ", 7)
        restore_limits()

        update(A, history=[
            {"from": "you", "prompt": "Сделай авторизацию через OAuth", "answer": "Сделал схему и callback, дальше тесты."},
            {"from": "agent", "prompt": "<agent-message from=\"a1\">Схема проверена: индексы на email и provider на месте.</agent-message>",
             "answer": "Принял отчёт агента, схема в порядке."},
            {"from": "you", "prompt": "А тесты?", "answer": ""}])
        step("ИСТОРИЯ: раскрой, открой alpha — лента из 3 обменов, второй — свёрнутая строка «👥 Сообщение от агента» (кликни — раскроется). Сверни", 15)

        update(A, status="done", tool="", activity="", turns=2, tasks=[],
               lastText="Готово ✓", history=[{"from": "you", "prompt": "А тесты?", "answer": "Тесты зелёные ✓"}])
        new_session(G, "gamma", "Переименуй модуль")
        update(G, status="error", activity="", lastText="**Error:** You've hit your usage limit · resets 4am",
               history=[{"from": "you", "prompt": "Переименуй модуль", "answer": "**Error:** You've hit your usage limit · resets 4am"}])
        step("ОШИБКА: слева ⚠ красный, справа точка. Раскрой, открой gamma — «Error: You've hit your usage limit…». Сверни", 12)

        update(G, status="aborted", lastText="")
        step("ПРЕРВАНО: слева ⏹ серый «стоп»", 5)
        update(G, status="done", turns=2, lastText="`/cost`\n\nTotal cost: $0.42\nTotal duration: 3m 12s",
               history=[{"from": "you", "prompt": "/cost", "answer": "Total cost: $0.42\nTotal duration: 3m 12s"}])
        step("ГОТОВО: слева ✓ зелёная. В карточке gamma — вывод команды /cost", 6)

        log("ДАЛЬШЕ РЕШЕНИЯ: ответь в чёлке")
        update(A, status="working", tool="", activity="Thinking…", turnStartedAt=now_ms())
        threading.Thread(target=ask, args=(G, {"id": "perm-rm", "kind": "permission", "tool": "Bash",
                         "summary": "Удалить старую папку", "detail": "rm -rf legacy/", "canAlways": False}), daemon=True).start()
        log("ЖДИ В ЧЁЛКЕ → РАЗРЕШЕНИЕ: слева 🔔 качается, справа 🔒 жёлтый. Кликни по чёлке — откроется на нём")
        time.sleep(4)
        ask(A, {"id": "q-next", "kind": "question", "questions": [{
            "question": "Что делаем дальше?", "header": "План", "multiSelect": False,
            "options": [{"label": "Тесты"}, {"label": "Деплой"}]}]})
        log("(вопрос alpha: слева 🔔, справа «?»)")
        time.sleep(2)
        update(A, status="done", tool="", activity="", turns=3, lastText="Готово ✓",
               history=[{"from": "you", "prompt": "Что делаем дальше?", "answer": "Готово ✓"}])
        step("всё закончено: ✓. Через 30 с без событий чёлка уйдёт в тихий режим (тусклая ✳︎). Конец через 35 с", 35)
    finally:
        restore_limits()
        STOP = True
        for sid in list(SESSIONS):
            try:
                os.remove(f"{W}/sessions/{sid}.json")
            except FileNotFoundError:
                pass
        log("конец")


def parallel():
    """Two chats work side by side; one finishes first."""
    global STOP
    for d in ("sessions", "answers", "inbox"):
        os.makedirs(f"{W}/{d}", exist_ok=True)
    A, B = "demo-alpha", "demo-beta"
    threading.Thread(target=heartbeat, daemon=True).start()
    new_session(A, "alpha", "Сделай авторизацию")
    update(A, tool="Edit", activity="Edit auth.ts")
    new_session(B, "beta", "Почини сборку")
    update(B, tool="Bash", activity="npm run build")
    step("иконка работы слева, справа «…» (работают оба)", 6)
    update(B, status="done", tool="", activity="", turns=2, lastText="Сборка зелёная ✓")
    step("3 с: ✓ слева подпрыгивает, справа точка; потом иконка работы alpha с зелёной точкой в углу", 8)
    step("раскрой чёлку: у beta зелёная точка в строке; сверни — точка в углу пропадёт", 15)
    update(A, status="done", tool="", activity="", turns=2, lastText="Готово ✓")
    step("✓ подпрыгивает 3 с, потом ✓ готово", 8)
    STOP = True
    for sid in list(SESSIONS):
        try:
            os.remove(f"{W}/sessions/{sid}.json")
        except FileNotFoundError:
            pass
    log("конец")


if __name__ == "__main__":
    import signal

    def interrupt(*_):
        raise KeyboardInterrupt

    # Ctrl+C and kill both end the run through its cleanup (it removes its cards, restores limits).
    signal.signal(signal.SIGINT, interrupt)
    signal.signal(signal.SIGTERM, interrupt)
    with open(FEEDBACK, "a") as f:
        f.write(f"\n## Прогон {time.strftime('%Y-%m-%d %H:%M')}\n\n")
    if INTERACTIVE:
        log("Шаги идут по Enter: пустой Enter — дальше, текст + Enter — заметка к шагу "
            f"(сохраняется в {FEEDBACK}).")
    else:
        threading.Thread(target=feedback_reader, daemon=True).start()
    try:
        if len(sys.argv) > 1 and sys.argv[1] == "states":
            stop_previous_run()
            states()
        elif len(sys.argv) > 1 and sys.argv[1] == "parallel":
            stop_previous_run()
            parallel()
        else:
            main()
    except KeyboardInterrupt:
        log("остановлено")
    finally:
        STOP = True
        # Whatever the scenario and however it ended, its cards go.
        for sid in list(SESSIONS):
            try:
                os.remove(f"{W}/sessions/{sid}.json")
            except FileNotFoundError:
                pass
