# ДЗ "Практическое применение Docker" Борис Горелик

## Задание 1

Создан [Dockerfile.python](Dockerfile.python) с двумя стадиями `builder` и `runtime` на основе `python:3.12-slim`. Зависимости устанавливаются в виртуальное окружение на первой стадии, затем окружение копируется в финальный образ вместе с исходным кодом приложения.

Создан [.dockerignore](.dockerignore), исключающий `.env`, Git-метаданные, виртуальные окружения, кэш Python, документацию, скриншоты и другие файлы, не нужные приложению. Обязательные `COPY . .` и команда запуска Uvicorn сохранены.

![](docs/Снимок1_1.png)

## Задание 3
Создан [compose.yaml](compose.yaml), который подключает [proxy.yaml](proxy.yaml) директивой `include`. Включённый файл содержит оба прокси и bridge-сеть с точным именем `backend`.

- **web:** сборка из `Dockerfile.python`, адрес `172.20.0.5`, `restart: always`.
- **db:** образ `mysql:8`, адрес `172.20.0.10`, `restart: on-failure`, постоянный том `mysql_data`.
- **Подключение к БД:** `DB_HOST=db`; имя базы, пользователь и пароли подставляются из существующего `.env`, без публикации реальных секретов.
- **Готовность сервисов:** приложение запускается после успешного healthcheck MySQL.

Запуск и HTTP-проверка:

```bash
sudo docker compose config --quiet
sudo docker compose up -d --build --wait --wait-timeout 240
sudo docker compose ps
curl -L http://127.0.0.1:8090
```

![](docs/Снимок2_1.png)

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

![](docs/Снимок2_2.png)

После сохранения скриншота локальный проект остановлен командой `docker compose down`. Отдельная проверка `docker compose ps -a` при подготовке этого отчёта также показала отсутствие контейнеров локального проекта; том базы данных не удалялся.

## Задание 4

Создана ВМ `docker-compose-lab`: Ubuntu 24.04 LTS, 2 vCPU, 2 ГиБ RAM и диск 20 ГиБ, зона `ru-central1-a`. В ходе выполнения задания внешний IP был `51.250.69.238`; подключение по SSH и установка Docker выполнены через Yandex Cloud Shell.

Подготовлен [scripts/deploy-yc.sh](scripts/deploy-yc.sh), который устанавливает Docker при его отсутствии, клонирует fork в `/opt/hw_docker_2` и запускает весь Compose-проект. При первом развёртывании примерные пароли из существующего `.env` заменяются случайными локальными значениями; реальные пароли не коммитятся и не показываются на скриншотах.

Команды запуска на Ubuntu-ВМ:

```bash
curl --fail --silent --show-error --location \
  https://raw.githubusercontent.com/brg171171/hw_docker_2/main/scripts/deploy-yc.sh \
  --output /tmp/deploy-yc.sh
```

### Проверка HTTP извне

![Задание 3: внешняя HTTP-проверка через Check-Host](docs/yc-check-host-http.jpg)

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

![Задание 3: SQL-запрос на ВМ Yandex Cloud](docs/yc-mysql-sql-requests.jpg)

## Задание 6

![](docs/terraform-dive-layer.jpg)

![](docs/Снимок3_3.png)

![](docs/Снимок3_5.png)
