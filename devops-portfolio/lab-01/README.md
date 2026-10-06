# Лабораторна робота №1 — Звіт

## Завдання 1. Git і редактор

Вивід глобальних налаштувань Git (`git config --list --global`):

```text
core.editor=code --wait
core.autocrlf=input
filter.lfs.process=git-lfs filter-process
filter.lfs.required=true
filter.lfs.clean=git-lfs clean -- %f
filter.lfs.smudge=git-lfs smudge -- %f
user.name=mila130106
user.email=yeremichukk@gmail.com
http.postbuffer=524288000
init.defaultBranch=main
pull.rebase=true1.

1. Чому значення core.autocrlf різне для Windows і Unix, і що станеться в команді зі змішаними системами, якщо його не задати?

Операційні системи використовують різні символи для закінчення рядка (CRLF у Windows і LF у Unix/macOS). Якщо цей параметр не налаштувати у проєкті, де працюють розробники з різними ОС, Git почне автоматично перезаписувати кінці рядків при кожному коміті, через що історія заповниться хибними змінами.

2. Чим історія з pull.rebase=true відрізняється від типової?

Звичайна поведінка (merge) при отриманні змін створює зайвий коміт злиття, якщо є розбіжності. Режим rebase=true тимчасово прибирає твої локальні коміти, оновлює гілку з репозиторію, а потім акуратно накладає твої коміти зверху, роблячи історію абсолютно рівною та лінійною.

Завдання 1 (продовження). Налаштування .editorconfig
Файл .editorconfig у коріні репозиторію слугує для підтримки єдиного стилю форматування коду.

editorconfig-check.png

Завдання 2. Встановлення Node.js через менеджер версій (fnm)
Для керування версіями Node.js було встановлено менеджер fnm. Успішно перевірено роботу з версіями v20.18.0 та v22.11.0.

fnm-switch.png
