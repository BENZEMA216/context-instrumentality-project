"""Exercise owner import, summary search and lock against a temporary real Vault."""

import os
import tempfile
import threading
from pathlib import Path
from urllib.parse import urlsplit

from playwright.sync_api import expect, sync_playwright

from context_vault.service import Service, VaultHTTP


def smoke(origin, service, directory):
    selected = "BROWSER_SELECTED_KEY"
    discarded = "BROWSER_DISCARDED_KEY"
    secret = "fixture-chosen-value-b496"
    other_secret = "fixture-unselected-value-edc8"
    env_file = directory / ".env.local"
    env_file.write_text(f"{discarded}={other_secret}\n{selected}={secret}\n")

    expect.set_options(timeout=15000)
    with sync_playwright() as playwright:
        browser = playwright.chromium.launch(channel=os.getenv("CONTEXT_VAULT_SMOKE_CHANNEL"))
        context = browser.new_context(service_workers="block")
        page = context.new_page()
        requests, summaries, errors = [], [], []

        def observe_summary(response):
            if response.request.method == "GET" and urlsplit(response.url).path == "/api/items":
                summaries.append(response)

        page.on("response", observe_summary)
        page.on("pageerror", lambda error: errors.append(str(error)))

        def capture(route):
            request = route.request
            requests.append((request.method, request.url, request.post_data or ""))
            if request.url.startswith(origin + "/"):
                route.continue_()
            else:
                route.abort()

        context.route("**/*", capture)
        page.goto(origin + "/#token=owner-smoke")
        page.locator("#gate-value").fill("temporary synthetic password")
        page.locator("#gate-repeat").fill("temporary synthetic password")
        page.locator("#gate-submit").click()
        expect(page.locator("#library")).to_be_visible()
        assert page.url == origin + "/"
        sheet = page.get_by_role("dialog")
        rows = page.locator("#groups .row")

        def select_key(name):
            page.get_by_role("button", name="添加API 密钥", exact=True).click()
            sheet.locator("summary").click()
            sheet.get_by_label("选择 .env 文件").set_input_files(env_file)
            choice = sheet.get_by_label("变量名")
            expect(choice).to_be_enabled()
            choice.select_option(label=name)

        select_key(discarded)
        sheet.get_by_role("button", name="取消").click()
        expect(sheet).to_have_count(0)
        assert service.store.list_items() == []
        assert all(other_secret not in (url + body) for _, url, body in requests)

        select_key(selected)
        sheet.get_by_role("button", name="保存资料").click()
        expect(rows).to_have_count(1)
        expect(rows.first).to_contain_text(selected)
        saved = service.store.list_items()
        assert [item["label"] for item in saved] == [selected]
        assert service.store.get_item(saved[0]["id"])["value"] == secret

        search = page.get_by_role("searchbox")
        search.fill(secret)
        expect(rows).to_have_count(0)
        expect(page.locator("#search-result")).to_contain_text("没有匹配")
        search.fill(selected)
        expect(rows).to_have_count(1)
        expect(page.locator("#search-result")).to_contain_text("找到 1 项")
        assert not any(urlsplit(url).path.startswith("/api/items/") for _, url, _ in requests)

        page.get_by_role("button", name="锁定", exact=True).click()
        expect(page.locator("#gate-title")).to_have_text("解锁保险库")
        expect(page.locator("#library")).to_be_hidden()
        expect(page.locator("#item-search")).to_have_value("")
        expect(page.locator("#groups")).to_be_empty()
        expect(page.locator("#sheet-content")).to_be_empty()
        assert not service.store.unlocked
        assert selected not in page.locator("body").text_content()
        assert all(url.startswith(origin + "/") for _, url, _ in requests)
        assert all(other_secret not in (url + body) for _, url, body in requests)
        assert [(method, urlsplit(url).path) for method, url, body in requests if secret in url + body] == [
            ("POST", "/api/items")
        ]
        returned = [item for response in summaries for item in response.json()["items"]]
        assert any(item["label"] == selected for item in returned)
        assert all("value" not in item for item in returned)
        assert not errors, errors
        print(f"Vault owner browser smoke passed (Chromium {browser.version}).")
        context.close()
        browser.close()


def main():
    with tempfile.TemporaryDirectory(prefix="context-vault-browser-") as temp:
        directory = Path(temp)
        service = Service(directory / "vault", "owner-smoke", "agent-smoke")
        with VaultHTTP(("127.0.0.1", 0), service) as server:
            worker = threading.Thread(target=server.serve_forever, daemon=True)
            worker.start()
            try:
                smoke(f"http://127.0.0.1:{server.server_port}", service, directory)
            finally:
                server.shutdown()
                worker.join()
                service.lock()


if __name__ == "__main__":
    main()
