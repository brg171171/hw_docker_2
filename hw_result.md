# Результаты домашней работы по Docker

Выполнены четыре задания: multistage-сборка Python-приложения, запуск через Docker Compose, развёртывание в Yandex Cloud и извлечение Terraform из Docker-образа. Ниже приведены конфигурации, команды проверки и скриншоты фактических результатов от 4 ноября 2026 года.

Fork проекта: [brg171171/hw_docker_2](https://github.com/brg171171/hw_docker_2). Исходный репозиторий: [netology-code/shvirtd-example-python](https://github.com/netology-code/shvirtd-example-python).

## Задание 1: Dockerfile.python и multistage-сборка

Создан [Dockerfile.python](Dockerfile.python) с двумя стадиями `builder` и `runtime` на основе `python:3.12-slim`. Зависимости устанавливаются в виртуальное окружение на первой стадии, затем окружение копируется в финальный образ вместе с исходным кодом приложения.

```dockerfile
FROM python:3.12-slim AS builder

ENV PIP_DISABLE_PIP_VERSION_CHECK=1
WORKDIR /build

COPY requirements.txt .
RUN --mount=type=secret,id=pip_ca \
    if [ -f /run/secrets/pip_ca ]; then export PIP_CERT=/run/secrets/pip_ca; fi \
    && python -m venv /opt/venv \
    && /opt/venv/bin/pip install --no-cache-dir -r requirements.txt

FROM python:3.12-slim AS runtime

ENV PATH="/opt/venv/bin:$PATH" \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /app
COPY --from=builder /opt/venv /opt/venv
COPY . .

EXPOSE 5000
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "5000"]
```

Создан [.dockerignore](.dockerignore), исключающий `.env`, Git-метаданные, виртуальные окружения, кэш Python, документацию, скриншоты и другие файлы, не нужные приложению. Обязательные `COPY . .` и команда запуска Uvicorn сохранены.

Команды повторения проверки:

```bash
sudo docker build -f Dockerfile.python -t shvirtd-example-python-web .
sudo docker run --rm shvirtd-example-python-web python --version
sudo docker run --rm shvirtd-example-python-web python -m pip check
```

Сборка фактически выполнена успешно в локальном Docker Engine, а затем повторена при развёртывании на облачной ВМ. В локальной песочнице для доверия TLS-прокси использован необязательный BuildKit secret `pip_ca`; на обычной Ubuntu-ВМ он не требуется, отключение проверки TLS не используется.

При повторной проверке для отчёта получены `Python 3.12.16` и `No broken requirements found.`. На скриншоте также показана обязательная команда запуска Uvicorn в конфигурации собранного образа.

![Задание 1: multistage-сборка, версия Python, зависимости и CMD](docs/python-multistage-check.jpg)

В репозитории также добавлен [workflow сборки и smoke-теста](.github/workflows/docker-python.yml). Подтверждением выполнения здесь служат локальная сборка и работа приложения в Compose; успешное завершение GitHub Actions отдельно не заявляется.

## Задание 2: Docker Compose и локальная проверка SQL

Создан [compose.yaml](compose.yaml), который подключает [proxy.yaml](proxy.yaml) директивой `include`. Включённый файл содержит оба прокси и bridge-сеть с точным именем `backend`.

- **web:** сборка из `Dockerfile.python`, адрес `172.20.0.5`, `restart: always`.
- **db:** образ `mysql:8`, адрес `172.20.0.10`, `restart: on-failure`, постоянный том `mysql_data`.
- **Подключение к БД:** `DB_HOST=db`; имя базы, пользователь и пароли подставляются из существующего `.env`, без публикации реальных секретов.
- **Готовность сервисов:** приложение запускается после успешного healthcheck MySQL.

Имя сервиса базы данных в конфигурации равно `db`, поэтому именно оно используется как `DB_HOST`. Сервис `web` является клиентом MySQL, а не сервером базы данных.

```yaml
include:
  - proxy.yaml
```

Запуск и HTTP-проверка:

```bash
sudo docker compose config --quiet
sudo docker compose up -d --build --wait --wait-timeout 240
sudo docker compose ps
curl -L http://127.0.0.1:8090
```

Запрос направлялся на порт `8090`, через Nginx и HAProxy к приложению. Ответ содержал время и адрес `127.0.0.1`, а соответствующие записи появились в MySQL; на локальном SQL-скриншоте показаны шесть записей.

Подключение к MySQL без печати пароля в командной строке хоста:

```bash
DB_CONTAINER=$(sudo docker compose ps -q db)
sudo docker exec -ti "$DB_CONTAINER" \
  sh -c 'exec mysql -uroot -p"$MYSQL_ROOT_PASSWORD"'
```

В клиенте MySQL выполнены команды:

```sql
show databases;
use virtd;
show tables;
SELECT * from requests LIMIT 10;
```

![Задание 2: базы данных, таблица requests и результат SQL-запроса](docs/mysql-sql-requests.jpg)

После сохранения скриншота локальный проект остановлен командой `docker compose down`. Отдельная проверка `docker compose ps -a` при подготовке этого отчёта также показала отсутствие контейнеров локального проекта; том базы данных не удалялся.

Подробный порядок повторения: [COMPOSE-LAB.md](COMPOSE-LAB.md).

## Задание 3: развёртывание в Yandex Cloud

Создана ВМ `docker-compose-lab`: Ubuntu 24.04 LTS, 2 vCPU, 2 ГиБ RAM и диск 20 ГиБ, зона `ru-central1-a`. В ходе выполнения задания внешний IP был `51.250.69.238`; подключение по SSH и установка Docker выполнены через Yandex Cloud Shell.

Подготовлен [scripts/deploy-yc.sh](scripts/deploy-yc.sh), который устанавливает Docker при его отсутствии, клонирует fork в `/opt/hw_docker_2` и запускает весь Compose-проект. При первом развёртывании примерные пароли из существующего `.env` заменяются случайными локальными значениями; реальные пароли не коммитятся и не показываются на скриншотах.

Команды запуска на Ubuntu-ВМ:

```bash
curl --fail --silent --show-error --location \
  https://raw.githubusercontent.com/brg171171/hw_docker_2/main/scripts/deploy-yc.sh \
  --output /tmp/deploy-yc.sh

# Проверить содержимое перед запуском с правами root.
less /tmp/deploy-yc.sh
bash -n /tmp/deploy-yc.sh
sudo bash /tmp/deploy-yc.sh
```

Развёртывание завершилось с кодом `0`: запущены `web`, `db`, `reverse-proxy` и `ingress-proxy`. Запросы к `http://51.250.69.238:8090` проходили по следующей цепочке:

```text
Пользователь -> Internet -> Nginx -> HAProxy -> FastAPI
                                               |
                                          запись в MySQL
                                               |
Пользователь <- Internet <- Nginx <- HAProxy <---+
```

### Проверка HTTP извне

Выполнена проверка через [Check-Host, отчёт 558cf370k342](https://check-host.net/check-report/558cf370k342). В сохранённом запуске 53 из 55 узлов получили HTTP `200 OK`, два узла завершились тайм-аутом; результаты всех узлов сохранены в [JSON-файле](docs/check-host-http-2026-11-04.json).

![Задание 3: внешняя HTTP-проверка через Check-Host](docs/yc-check-host-http.jpg)

Это результат конкретной проверки, а не утверждение о постоянной доступности сервиса. Публичный адрес ВМ динамический и может измениться после её остановки и повторного запуска.

### SQL на облачной ВМ

На сервере повторены запросы к базе `virtd`:

```sql
show databases;
use virtd;
show tables;
SELECT * from requests LIMIT 10;
SELECT COUNT(*) AS total_requests,
       COUNT(DISTINCT request_ip) AS distinct_ips
FROM requests;
```

На момент снимка, 4 ноября 2026 года в 17:35:05 UTC, в таблице находилось 55 записей с 55 различными IP-адресами. В первых десяти строках видны локальная проверка, запрос Cloud Shell и внешние запросы узлов Check-Host.

![Задание 3: SQL-запрос на ВМ Yandex Cloud](docs/yc-mysql-sql-requests.jpg)

### Необязательный Docker SSH context

Создан и проверен временный context `yc-lab` с endpoint `ssh://ubuntu@51.250.69.238`. Выполнены `docker context ls` и `docker --context yc-lab ps -a`, показавшие четыре контейнера проекта.

![Задание 3: Docker SSH context и удалённый docker ps -a](docs/yc-docker-context.jpg)

После демонстрации временный context, копия SSH-ключа в Cloud Shell и временные правила SSH-доступа удалены. Облачная ВМ по согласованию оставлена работающей; требование остановить проект в задании 2 относится к локальному запуску, а не к облачной ВМ.

Подробности развёртывания и команды повторения: [YANDEX-CLOUD-LAB.md](YANDEX-CLOUD-LAB.md).

## Задание 4: извлечение Terraform через dive и docker save

Скачан образ `hashicorp/terraform:latest` для `linux/amd64`. С помощью `dive` найден слой с командой `COPY dist/linux/amd64/terraform /bin/terraform`, после чего файл извлечён из архива `docker save` без использования `docker cp`.

Задание выполнено в локальном рабочем окружении этой задачи, отдельно от облачной ВМ. Скриншоты не выдаются за действия на физическом компьютере пользователя.

### Скачивание и сохранение образа

```bash
sudo docker pull hashicorp/terraform:latest
sudo docker save --output terraform-latest.tar hashicorp/terraform:latest
sudo chown "$(id -u):$(id -g)" terraform-latest.tar
mkdir -p image
tar -xf terraform-latest.tar -C image
jq '.[0] | {RepoTags, Config, Layers}' image/manifest.json
```

Digest скачанного образа:

```text
sha256:a5d5a5a892c98f60fcbfa81eac2a40fc19e7b3fa7719bccae10ff6111d22524a
```

![Задание 4: успешный docker pull и проверка платформы](docs/terraform-docker-pull.jpg)

![Задание 4: docker save и manifest.json](docs/terraform-docker-save.jpg)

### Поиск слоя в dive

Для анализа использован `dive 0.13.1`:

```bash
./tools/dive --source docker-archive terraform-latest.tar
```

В интерфейсе выбран слой, добавляющий `/bin/terraform`, и применён фильтр `terraform`. На скриншоте слева видна команда `COPY`, справа файл `terraform` в каталоге `bin`.

![Задание 4: слой с /bin/terraform в dive](docs/terraform-dive-layer.jpg)

### Извлечение файла и проверка

В сохранённом образе нужным оказался четвёртый, последний слой. Его путь получен из `manifest.json`, а не из случайного имени архива:

```bash
layer=$(jq -r '.[0].Layers[3]' image/manifest.json)
tar -tvf "image/$layer" bin/terraform
tar -xvf "image/$layer" --strip-components=1 bin/terraform
chmod +x ./terraform
./terraform version
sha256sum ./terraform
```

Для повторения с другим содержимым тега `latest` следует заново найти нужный слой в `dive`, а не полагаться на индекс `3`. В данном запуске архив слоя имел путь:

```text
blobs/sha256/2d664eecf5e7d017570e58c8cec8a8a65adff55b713f5f370bfddd22a0698cb6
```

Файл извлечён в `/home/user/workspace/terraform-image-lab/terraform`. Непосредственный запуск вне контейнера вернул:

```text
Terraform v1.17.1
on linux_amd64
```

Контрольная сумма SHA256:

```text
1eaecd79a92a0114d70017b5d5e274c12e5b4561d971ff0b5e24073cddd287dc
```

Отдельно рассчитана SHA256 содержимого `bin/terraform` внутри сохранённого слоя: она совпала с SHA256 извлечённого файла. Образ и архив не добавлялись в Git из-за их размера; в репозиторий включены команды и скриншоты.

![Задание 4: извлечение tar, права, запуск Terraform и SHA256](docs/terraform-extract-version.jpg)
