# История изменений

Формат основан на [Keep a Changelog](https://keepachangelog.com/ru/1.1.0/);
версии проекта следуют [Semantic Versioning](https://semver.org/lang/ru/).

## [Unreleased]

## [1.0.1] - 2026-07-28

### Добавлено

- agent-driven защищённый ввод subscription URL через скрытый системный диалог
  macOS без ручного создания файлов пользователем.
- agent-managed source checkout в application-data без требования
  пользовательского каталога `~/Projects`.

## [1.0.0] - 2026-07-28

### Добавлено

- production-handoff для человека и AI-агента;
- offline test suite и единая команда `make test`;
- безопасный `--dry-run`, `xst doctor` и user/system launchd scope;
- независимые опциональные команды `claude-xst` с session-scoped
  proxy/NO_PROXY без изменения контекста и `claude-xst-aware` с несекретной
  route-инструкцией для Claude Code;
- описание формата подписки и трёх слоёв split tunneling;
- runbook интеграции с Citrix через `secure-access-helper`;
- безопасная миграция с legacy LaunchDaemon `com.nqs.xray`;
- политика безопасности и защита локальных секретов через
  `.gitignore`.

### Изменено

- subscription URL передаётся через заранее созданный файл с правами `0600`, а
  не через чат, аргументы команды или переменные окружения;
- конфиденциальные bypass domains/CIDR для автоматизации передаются через
  защищённый `XST_BYPASS_FILE`, а не process environment;
- установка использует стабильный source checkout без привязки к структуре
  пользовательских проектов;
- изменение `~/.zshrc` требует явного выбора `XST_ZSHRC=0` или
  `XST_ZSHRC=1`;
- критерии автоматической и ручной приёмки разделены;
- runtime env теперь data-only и никогда не исполняется через `source`;
- subscription ограничена HTTPS-only/10 MiB/512 candidate elements, не
  попадает в curl argv и не наследует `~/.curlrc`;
- provider inbounds/DNS/API/logging отбрасываются, `direct`/`block` создаются
  проектом, domain bypass проверяется до IP;
- update сохраняет сервер только по однозначному case-insensitive exact имени,
  а не по изменяемому индексу;
- mutating-операции используют fail-fast ownership lock, а чужой/non-managed
  state и foreign/opposite-scope plist не перезаписываются;
- apply/update используют snapshot и rollback runtime-файлов при неудачном
  restart; install transaction отделена от поздней live/Citrix acceptance;
- migration runbook сохраняет durable legacy plist вне LaunchDaemons и
  описывает отдельный ручной rollback `com.nqs.xray`;
- release-архив содержит export-subst `REVISION`, который сверяется с
  manifest commit; проверка криптографической подписи тега не заявляется;
- uninstall принимает только известные аргументы и требует ownership marker
  перед удалением состояния; lock release и purge tombstone защищены от
  обрабатываемых сигналов.
