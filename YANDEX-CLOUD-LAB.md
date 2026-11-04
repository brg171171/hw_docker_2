# Развёртывание проекта в Yandex Cloud

## Статус

Подготовлен `scripts/deploy-yc.sh`. Создание ВМ, SSH-подключение, внешний
HTTP-тест и SQL-скриншот с облачного сервера требуют доступа к Yandex Cloud.
Ранее сохранённый `docs/mysql-sql-requests.jpg` относится к локальной песочнице,
а не к облачной ВМ, и не заменяет скриншот этого задания.

Локальная проверка скрипта выполнена 4 ноября 2026 года:

- `bash -n` прошёл без ошибок.
- Полный запуск создал checkout `/opt/hw_docker_2` и поднял все четыре сервиса.
- Ответ через порт 8090 содержал время и IP; запрос записался в MySQL.
- Повторный запуск сохранил `.env` без изменений и существующую БД:
  число записей выросло с 1 до 2.
- `.env` принадлежит root и имеет права `0600`.
- После теста локальный проект остановлен с сохранением тома.

Эта проверка не подтверждает создание ВМ или внешний HTTP-доступ.
В локальном окружении Docker уже был установлен, поэтому ветка первичной
установки Docker CE на чистой Ubuntu пока не проверена исполнением.

## План ВМ

Предлагаемые параметры учебного стенда:

- Ubuntu 24.04 LTS, пользователь `ubuntu`, вход по SSH-ключу.
- 2 vCPU, 2 ГБ RAM, загрузочный диск 20 ГБ.
- Динамический публичный IPv4.
- Отдельная группа безопасности: входящий TCP 8090 из интернета,
  TCP 22 только с адреса управления, исходящий доступ для установки пакетов.
- Порты 3306, 5000 и 8080 не открываются в облачной группе безопасности.

Создание и работа ВМ, диска и публичного адреса тарифицируются.
Конкретный каталог и зона выбираются перед созданием ВМ.
Инструкция по созданию:
[Yandex Cloud](https://yandex.cloud/ru/docs/compute/quickstart/quick-create-linux).

## SSH и запуск скрипта

Команды выполняются с управляющего компьютера, где находится SSH-ключ:

```bash
ssh -i ~/.ssh/yc_lab ubuntu@PUBLIC_IP
```

На Ubuntu-ВМ:

```bash
sudo cloud-init status --wait

curl --fail --silent --show-error --location \
  https://raw.githubusercontent.com/brg171171/hw_docker_2/main/scripts/deploy-yc.sh \
  --output /tmp/deploy-yc.sh

# Проверить скачанный код перед запуском с root.
less /tmp/deploy-yc.sh
bash -n /tmp/deploy-yc.sh
sudo bash /tmp/deploy-yc.sh
```

`PUBLIC_IP` и путь к ключу являются обозначениями: заменить их фактическими
значениями. Команда `cloud-init status --wait` выполняется, если `cloud-init`
установлен в выбранном образе.

Скрипт:

- На новой Ubuntu устанавливает Docker Engine и Compose plugin из официального
  репозитория, если Docker ещё не установлен; существующий runtime не удаляет.
- Проверяет Compose 2.20.0+ и наличие Buildx.
- Клонирует fork в `/opt/hw_docker_2`.
- При первом запуске заменяет примерные пароли из публичного `.env` случайными
  локальными значениями, сохраняя имена БД и пользователя.
- Сохраняет `.env` с правами `0600`, не выводит пароли и не коммитит их.
- При повторном запуске сохраняет пароли и том базы данных.
- Запускает проект с именем Compose `hw-docker-2`, включая оба прокси.
- Делает HTTP-запрос через порт 8090 и проверяет запись запроса в MySQL.

Установка Docker основана на
[официальной инструкции для Ubuntu](https://docs.docker.com/engine/install/ubuntu/).
Скрипт не создаёт облачную ВМ и не меняет её группу безопасности.
Он также не отключает TLS-проверку и не применяет обходы iptables из песочницы.

## Проверка извне

С управляющего компьютера:

```bash
curl --fail -L http://PUBLIC_IP:8090
```

В браузере открыть [Check-Host HTTP](https://check-host.net/check-http),
ввести `http://PUBLIC_IP:8090` и запустить проверку. После её завершения
сохранить ссылку на результат и скриншот.

Путь запроса:

```text
внешний проверяющий узел -> Internet -> PUBLIC_IP:8090
  -> Nginx -> HAProxy -> FastAPI -> запись в MySQL
  -> HAProxy -> Nginx -> Internet -> проверяющий узел
```

Для подтверждения внешней проверки в `requests` должны появиться адреса
внешних проверяющих узлов, а не только локальный `127.0.0.1`.

## SQL на облачной ВМ

На сервере:

```bash
cd /opt/hw_docker_2

sudo docker compose -p hw-docker-2 ps
DB_CONTAINER=$(sudo docker compose -p hw-docker-2 ps -q db)

sudo docker exec -ti "$DB_CONTAINER" \
  sh -c 'exec mysql -uroot -p"$MYSQL_ROOT_PASSWORD"'
```

В клиенте MySQL:

```sql
show databases;
use virtd;
show tables;
SELECT * from requests LIMIT 10;
SELECT * from requests WHERE request_ip <> '127.0.0.1' ORDER BY id DESC LIMIT 10;
exit;
```

Если имя БД изменено, заменить `virtd` своим значением `MYSQL_DATABASE`.
Первая выборка выполняет условие задания; вторая показывает последние внешние
запросы, даже если первые записи были локальными проверками.
Скриншот должен содержать SQL и реальные строки результата с облачной ВМ.
Не показывать содержимое `.env` или приватный SSH-ключ.

## Необязательный remote SSH context

Создать SSH alias на управляющем компьютере после проверки SSH host key.
Сам alias не меняет права пользователя на сервере:

```sshconfig
Host yc-docker-lab
    HostName PUBLIC_IP
    User ubuntu
    IdentityFile ~/.ssh/yc_lab
    IdentitiesOnly yes
    RequestTTY no
```

Если выбранный пользователь уже имеет разрешённый доступ к Docker,
создать context:

```bash
docker context create yc-lab \
  --description "Yandex Cloud Compose lab" \
  --docker "host=ssh://yc-docker-lab"

docker context ls
docker --context yc-lab ps -a
```

Context через SSH требует, чтобы SSH-пользователь мог запускать `docker`
на сервере без интерактивного пароля. Если доступ есть только через `sudo`,
проще выполнить обязательную часть напрямую:

```bash
ssh -i ~/.ssh/yc_lab ubuntu@PUBLIC_IP 'sudo -n docker ps -a'
```

Это удалённое выполнение через SSH, но не Docker context.
Не менять пользователя на root и не отключать проверку SSH host key ради
необязательного пункта. Официальное описание:
[Docker daemon over SSH](https://docs.docker.com/engine/security/protect-access/).

## Завершение

После сохранения результатов можно остановить проект:

```bash
cd /opt/hw_docker_2
sudo docker compose -p hw-docker-2 down
```

Это не удаляет облачную ВМ и не прекращает тарификацию её диска и других
сохраняемых ресурсов. Удаление ВМ и диска согласовывается отдельно,
если после сдачи стенд больше не нужен.
