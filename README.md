# FlashOS Manager

FlashOS Manager — это инструмент для управления операционной системой FlashOS на USB-устройствах.

## Версии

- **Linux / Bash**: `flashos.sh` (версия 0.3.0)
- **Windows / PowerShell**: `flashos.ps1` (версия 0.3.1-ps)

## Возможности

- Обнаружение USB-устройств
- Обнаружение и установка FlashOS
- Форматирование в exFAT
- Зашифрованное основное хранилище
- Режим хранилища (Vault Mode)
- Резервное копирование
- Диагностика
- Настройки
- Обновление до последней версии с GitHub
- Удаление FlashOS
- Интерактивный интерфейс (клавиатура)

## Установка и запуск

### Для Linux (Bash)

```bash
chmod +x flashos.sh
./flashos.sh
```

### Для Windows (PowerShell)

1. Откройте PowerShell от имени администратора.
2. Перейдите в папку с файлом:
   ```powershell
   cd C:\путь\к\папке
   ```
3. Запустите скрипт:
   ```powershell
   .\flashos.ps1
   ```

## Требования

- **Linux**: `lsblk`, `findmnt`, `udisksctl`, `gocryptfs`, `fusermount3`, `mkfs.exfat`, `curl`, `bash`, `jq`
- **Windows**: PowerShell 5.1+, права администратора

## Лицензия

Проект распространяется на условиях лицензии MIT (см. репозиторий).

## Репозиторий

[https://github.com/1xcoding/flashos](https://github.com/1xcoding/flashos)
