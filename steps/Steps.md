## Задание

Поднять отказоустойчивый кластер PostgreSQL (Master-Slave), используя:
- **keepalive**
- **patroni**
- **haproxy**

Должна быть одна точка входа для запросов в кластер, например, db.test.lan

Настроить балансер на 3 порта:
1 - смотрит всегда только на мастер
2 - смотрит всегда только на слейв
3 - балансит запросы по всем живым

С помощью patronictl узнать состояние кластера. 

С помощью patronictl поменять местами master/slave. 

С web ui haproxy определить состояние кластера. 

## 1. Создание виртуальных машин

Создаю следующие ноды:
1. Нода балансировщика **Haproxy** (**haproxydeb**).
```bash
sudo qm create 100 \
  --autostart 1 \
  --bios ovmf \
  --name haproxydeb \
  --cpu host \
  --cores 2 \
  --memory 1024 \
  --ide2 Hard1:iso/debian-12.9.0-amd64-netinst.iso,media=cdrom \
  --net0 bridge=vmbr0,model=virtio \
  --machine q35 \
  --scsihw virtio-scsi-single \
  --scsi0 Hard1:15

Formatting '/media/Hard1/proxmox/images/100/vm-100-disk-0.raw', fmt=raw size=16106127360 preallocation=off
scsi0: successfully created disk 'Hard1:100/vm-100-disk-0.raw,size=15G'
```

```bash
sudo qm config 100 

boot: order=scsi0;ide2;net0
cores: 1
cpu: x86-64-v2-AES
ide2: Hard1:iso/debian-12.9.0-amd64-netinst.iso,media=cdrom,size=632M
machine: q35
memory: 1024
meta: creation-qemu=9.0.2,ctime=1739877136
name: haproxydeb
net0: virtio=BC:24:11:9D:38:61,bridge=vmbr0
numa: 0
ostype: l26
scsi0: Hard1:100/vm-100-disk-0.qcow2,iothread=1,size=15G
scsihw: virtio-scsi-single
smbios1: uuid=2479505f-f493-4a8e-838f-24be1708d34b
sockets: 1
vmgenid: 13766f5f-fe30-48e4-9f1a-2c68a4018549
```

Редактирование **/etc/network/interfaces**, меняю DHCP на статику:
```ini
# вместо dhcp ставлю статику:
# было iface enps18 inet auto dhcp

iface enps18 inet static
	address 192.168.2.15/24
	gateway 192.168.2.1
```

```bash
sudo ifdown enp6s18 && sudo ifup enp6s18

# делаю бэкапы машин
sudo vzdump 100 --compress zstd --mode stop # аналогично с остальными
```

Склонировал созданную ВМ пару раз для остальных нод, внес такие же правки.
```bash
# создание виртуальных машин для кластера Postgres
sudo qm clone 100 101 --name "dbmaster" --full
sudo qm clone 101 102 --name "dbslave" --full
sudo qm clone 101 111 --name "etcd" --full
```

Поменял `etc/passwd`, `/etc/hostname` и `/etc/network/interfaces` на остальных. 

Для удобного обращения в сети изменил **hosts**-файл моей **openwrt**:
```bash
cat /etc/hosts

192.168.2.15 db.test.lan
192.168.2.16 db.master.lan
192.168.2.17 db.slave.lan
192.168.2.18 db.etcd.lan

192.168.2.20 db.test1.lan
192.168.2.100 db.vip.lan
```

Результат следующий:

![Pasted image 20250218203757](https://github.com/user-attachments/assets/143ceeb1-277b-4527-bda8-8f62b851dfef)


--- 
## 2. Формирование инвентаря Ansible

Для начала я раскидал ключи при помощи скрипта **bash**, который работает c инструментами **ssh-keyscan** и **ssh-pass**:

```yaml
#!/bin/bash

echo -e "\n\nДобавление ключей в доверенные\n\n"

read -p "Введите пароль: " pass

# Запрос подсети
read -p "Введите подсеть (например, 192.168.2): " subnet

# Запрос диапазона узлов
read -p "Введите диапазон (например, 10 20): " starting ending
echo -e "\n"

for i in $(seq $starting $ending); do
    ip="$subnet.$i"
    ssh-keyscan -H $ip >> ~/.ssh/known_hosts
    echo -e "\nВставка ключей в файл authorized_keys $ip \n"
    sshpass -p $pass ssh -o HostKeyAlgorithms=+ssh-rsa -o ConnectTimeout=4 -o KexAlgorithms=+diffie-hellman-group-exchange-sha1 -o KexAlgorithms=+diffie-hellman-group14-sha1 -o KexAlgorithms=+diffie-hellman-group1-sha1 -t root@$ip "
        for user_dir in /home/*; do
            mkdir -p \"\$user_dir/.ssh\"
            touch \"\$user_dir/.ssh/authorized_keys\"
            echo 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIL7lPzw1H3lW1v7uYW/W+i9UyEBXw0B0pOk+CLY2lrZ/ digitd@archPC' > \"\$user_dir/.ssh/authorized_keys\"
        done
        mkdir -p /root/.ssh
        echo 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIL7lPzw1H3lW1v7uYW/W+i9UyEBXw0B0pOk+CLY2lrZ/ digitd@archPC' > /root/.ssh/authorized_keys
        echo $pass | sudo -S systemctl restart ssh
    "
done

```

Следом я настроил инвентарь Ansible:
```yaml
[haproxy]
db.test.lan            

[haproxy_vip]
db.test1.lan

[master]
db.master.lan              

[slave]
db.slave.lan          

[etcd]
db.etcd.lan

[cluster:children]
haproxy
haproxy_vip
master
slave
etcd

[database:children]
master
slave

[vip_hap:children]
haproxy
haproxy_vip

[etcd_cluster:children]
master
slave
etcd

[cluster:vars]
ansible_user = root
ansible_port = 22
ansible_ssh_private_key_file =  ../ssh-keys/.keys/my_key
ansible_python_interpreter=auto_silent
```

И **ansible.cfg**:
```yaml
[defaults]
inventory = cluster.ini
timeout = 10
log_path = ./ansible_cluster.log
```

Ответ от нод пришел

![Pasted image 20250218211124](https://github.com/user-attachments/assets/83db0cde-3a1c-4afa-a869-bdf9ddffb4c1)
--- 

## 3. Плейбуки Ansible и тестирование postgresql

Для начала мне нужно было установить софт и запустить службы

```yaml
---
- name: Install haproxy and run service
  hosts: haproxy
  become: true
  gather_facts: false
  tasks:
    - name: Install HAProxy
      ansible.builtin.apt:
        name: haproxy
        state: present
        update_cache: true
        install_recommends: true

    - name: Check service status
      ansible.builtin.service:
        name: haproxy
        state: started
        enabled: true


- name: Install PostgreSQL and check status
  hosts: database
  become: true
  gather_facts: false
  tasks:
    - name: Install PostgreSQL
      ansible.builtin.apt:
        name: postgresql
        state: present
        update_cache: true
        install_recommends: false

    - name: Check service
      ansible.builtin.service:
        name: postgresql
        state: started
        enabled: true

```

Меняю порт на 5001 в файле postgresql.conf:
![Pasted image 20250218223251](https://github.com/user-attachments/assets/0a5dcb6d-9529-453e-a4fc-4c783ce9e5ad)


Захожу в базы данных и устанавливаю пароль для пользователя (в противном случае, подсоединение не сработает):
```sql
alter user master with password '12345678';
```

Подсоединение на мастер-ноду сработало.

![Pasted image 20250218224918](https://github.com/user-attachments/assets/3dc557ff-c953-4960-99fc-39df8064ad6d)

--- 
## 4. Keepalived

[Keepalived User Guide — Keepalived 1.4.3 documentation](https://keepalived.org/doc/)

**Keepalived** - это инструмент, который позволяет настроить **HA** (High Availability) кластер, тот есть тот, который является отказоустойчивым. Делается это при помощи **VIP** (Virtual IP). Благодаря этому, механизм **failover** работает.

Понятие **failover** используется для обозначания сутуации, когда при сбое одной ноды (например, MASTER), происходит переключение на резервную ноду (BACKUP).

Для начала организуем отказоустойчивое функционирование на уровне прокси. 

Для этого склонируем виртуальную машину, на которой функционирует прокси. Сделаем минорные правки на ней, а именно изменим hostname, ip-адреса, домашнего пользователя и его родную директорию.

![Pasted image 20250219101404](https://github.com/user-attachments/assets/2f56fa79-eb3c-4373-a368-667f805eb227)

Пока все ходит.

![Pasted image 20250219110124](https://github.com/user-attachments/assets/59511662-220b-417f-9199-ba5ff6fe91ea)

Теперь переходим к настройки **keepalived**

Настроил keepalived, назначив VIP (Virtual IP) на 192.168.2.100, теперь обращения, поступающие на этот адрес, будут перенаправляться на два разные HAProxy-узла. Работает это по принципу того, что db.test1.lan (192.168.2.20) является **MASTER**, а db.test.lan (192.168.2.15) у нас **BACKUP**.

Мастер Haproxy:
```json
vrrp_instance VI_1 {
    state MASTER
    interface enp6s18
    virtual_router_id 51
    priority 100
    advert_int 1
    authentication {
        auth_type PASS
        auth_pass strong_password123
    }

    virtual_ipaddress {
        192.168.2.100/0
    }
}
```


![Pasted image 20250219121207](https://github.com/user-attachments/assets/1e663cdf-6c0f-4ddb-828f-a13072863742)

После данных манипуляций, я могу подсоединяться к БД на db.master.lan, обращаясь к VIP, который может обращаться к нескольким нодам HAProxy.

![Pasted image 20250301170455](https://github.com/user-attachments/assets/5c1123c6-8667-4320-aa9b-e1740de67eaa)

Для **VRRP** (протокол для **VIP**) появился новый интерфейс 192.168.2.100

![Pasted image 20250219140900](https://github.com/user-attachments/assets/19df90dd-d7de-4ee3-b600-a7d7860fe058)

Проверка работоспособности после исполнения плейбука.

![Pasted image 20250219151215](https://github.com/user-attachments/assets/b669aed5-b9d9-4d30-9ca3-27d1452c0a4f)

## 5. Haproxy
[Haproxy Health Checks](https://www.haproxy.com/documentation/haproxy-configuration-tutorials/service-reliability/health-checks/)

Для начала настроим **Haproxy**, чтобы он отдавал страницу со статистикой. Делается это достаточно просто, если следовать документации:
```nginx
frontend stats
    mode http
    bind *:8404
    stats enable
    stats uri /stats
    stats refresh 10s
    stats admin if LOCALHOST
```
Изначально есть встроенный функционал, бэкенд настраивать не нужно, все работает и так. Выглядит страница так:

![Pasted image 20250219152544](https://github.com/user-attachments/assets/01d8cfd8-7377-4782-bc76-5b18c2a4ee69)

Настраиваю **Haproxy** по следующему принципу:
- Порт `5001` проксирует на **Мастер** ноду кластера **Patroni**.
- Порт `5002` ведет на реплику Patroni 
- Порт `5010` осуществляет балансировку.

Проверка на доступность **Мастера** и **Реплики** проводится по tcp-чеку:
`option tcp-check`

Балансировка кластера происходит по параметру `httpchk GET /primary`. **Patroni** предоставляет удобный **rest-api**, при помощи которого можно легко находить **Master** в кластере, если к нему обращаться. 


Работа **Haproxy**:
![Pasted image 20250223195750](https://github.com/user-attachments/assets/71e59259-b4a5-458e-bea8-ac9700e05335)

Так выглядит статистика, если параметр `httpchk GET /primary` не активен.

После некоторых правок балансинга, **Haproxy** сообщает, что **slave** не работает в бэкенде **pg_cluster**: 
![Pasted image 20250223234256](https://github.com/user-attachments/assets/ab44ca4b-8500-4102-adff-ab3cf33445c2)
Это нормальная ситуация, так как теперь проверка происходит по `httpchk`, что проверяет **/priority** у нод **patroni**. Сервер, который находится в статусе **лидера**, возвращает значение 200 - удачный get-запрос. Сервер в состоянии **реплики** отдает 503, что он не отвечает. Балансировка происходит по лидеру.

---
## 6. Patroni

[Introduction — Patroni 4.0.4 documentation](https://patroni.readthedocs.io/en/latest/)
[GitHub - etcd-io/etcd: Distributed reliable key-value store for the most critical data of a distributed system](https://github.com/etcd-io/etcd)

**Patroni** - это шаблон для организации HA (High Availability) для Postgres, используя Python. Для максимальной доступности, Patroni поддерживает разнообразные конфигурации дистрибьюции, такие как ZooKeeper, etcd, Consul.

### 5.1. etcd 

[Configuration flags \| etcd](https://etcd.io/docs/v3.2/op-guide/configuration/#--listen-client-urls)
[A Guide to etcd \| Baeldung](https://www.baeldung.com/java-etcd-guide)
[Williamdes's blog - Installing a distributed etcd cluster on Debian 12](https://blog.williamdes.eu/Infrastructure/tutorials/install-a-distributed-etcd-cluster/)
[Clustering Guide \| etcd](https://etcd.io/docs/v3.4/op-guide/clustering/)

**etcd** - строгое организованное хранилище данных **ключ-значение**, которого предоставляет надежный способ хранения данных. Таких данных, к которым хосты или сам кластер машин должны обращаться. В данном сценарии **etcd** используется для того, чтобы хранить состояние **PostgreSQL**-кластера, порой это необходимо для того, чтобы кластер оставался в рабочем состоянии. **etcd** используется в **kubernetes**, чтобы хранить важную чувствительную информацию про кластеры.

Конфигурационный файл находится по пути `/etc/default/etcd`. Пакеты: **etcd-server**
для запуска сервера, **etcd-client** для **etcdctl**.

> Важно создать директорию /var/lib/etcd/ и дать ей права etcd после установки etcd

```bash
mkdir -p /var/lib/etcd
chown etcd:etcd /var/lib/etcd
```
Без этого у меня не запускалась служба **/etcd/** на слейве.

Настроил **etcd** следующим образом (чтобы он принимал соединения):
```ini
ETCD_NAME="masterpg"
ETCD_LISTEN_CLIENT_URLS="http://192.168.2.16:2379,http://127.0.0.1:2379"
ETCD_ADVERTISE_CLIENT_URLS="http://192.168.2.16:2379"
ETCD_LISTEN_PEER_URLS="http://192.168.2.16:2380,http://127.0.0.1:2380"
ETCD_INITIAL_ADVERTISE_PEER_URLS="http://192.168.2.16:2380"
ETCD_INITIAL_CLUSTER="masterpg=http://192.168.2.16:2380,slavepg=http://192.168.2.17:2380,etcdpg=http://192.168.2.18:2380"
INITIAL_CLUSTER_STATE="new"
ETCD_INITIAL_CLUSTER_TOKEN="etcd-cluster"
ETCD_AUTO_COMPACTION_MODE="periodic"
ETCD_AUTO_COMPACTION_RETENTION="1h"
```
Оформил примерно тоже самое и для других двух нод (SLAVE и отдельная для ETCD), только указав их имена и адреса.

После первого запуска службы на всех нодах, проверки того, что все работает, и кластер образуется. Необходимо перейти в конфигурационный файл, чтобы кластер заново не пытался формироваться после перезапуска службы.

Делается это переводом переменой `INITIAL_CLUSTER_STATE` в состояние `existing`.

[How to check Cluster status \| etcd](https://etcd.io/docs/v3.5/tutorials/how-to-check-cluster-status/)

Проверка состояния нод у кластера:
```bash
root@dbmaster:~# etcdctl --cluster=true endpoint health
http://192.168.2.16:2379 is healthy: successfully committed proposal: took = 2.980262ms
http://192.168.2.17:2379 is healthy: successfully committed proposal: took = 5.127455ms
http://192.168.2.18:2379 is healthy: successfully committed proposal: took = 4.991805ms
```

Список мемберов и статусы:
![Pasted image 20250223133513](https://github.com/user-attachments/assets/3c834766-df88-4671-9f1c-cbbdcf8640fc)

Проверю работу утилитами, на всякий случай:
![Pasted image 20250223131013](https://github.com/user-attachments/assets/b2e0bb4b-7018-4c0a-88a9-c67e02193ae4)
> iftop, lsof -i

Ноды между собой коммуницируют, проверить это можно при помощи **iftop**:
![Pasted image 20250223131013](https://github.com/user-attachments/assets/23666f30-a240-448f-8296-c87ac634fffd)


И **lsof**:
```bash
etcd     17890     etcd    7u  IPv4 158008      0t0  TCP localhost:2380 (LISTEN)
etcd     17890     etcd    8u  IPv4 158009      0t0  TCP db.master.lan:2380 (LISTEN)
etcd     17890     etcd    9u  IPv4 158010      0t0  TCP localhost:2379 (LISTEN)
etcd     17890     etcd   10u  IPv4 158011      0t0  TCP db.master.lan:2379 (LISTEN)
etcd     17890     etcd   15u  IPv4 165752      0t0  TCP db.master.lan:50064->db.etcd.lan:2380 (ESTABLISHED)
etcd     17890     etcd   16u  IPv4 160307      0t0  TCP db.master.lan:44380->db.slave.lan:2380 (ESTABLISHED)
etcd     17890     etcd   17u  IPv4 160308      0t0  TCP db.master.lan:44382->db.slave.lan:2380 (ESTABLISHED)
etcd     17890     etcd   18u  IPv4 160319      0t0  TCP db.master.lan:2380->db.slave.lan:55312 (ESTABLISHED)
etcd     17890     etcd   19u  IPv4 160321      0t0  TCP db.master.lan:2380->db.slave.lan:55314 (ESTABLISHED)
etcd     17890     etcd   20u  IPv4 160355      0t0  TCP db.master.lan:59494->db.master.lan:2379 (ESTABLISHED)
etcd     17890     etcd   21u  IPv4 160340      0t0  TCP db.master.lan:44388->db.slave.lan:2380 (ESTABLISHED)
etcd     17890     etcd   22u  IPv4 160356      0t0  TCP db.master.lan:2379->db.master.lan:59494 (ESTABLISHED)
etcd     17890     etcd   23u  IPv4 160353      0t0  TCP localhost:42360->localhost:2379 (ESTABLISHED)
etcd     17890     etcd   24u  IPv4 160358      0t0  TCP localhost:2379->localhost:42360 (ESTABLISHED)
etcd     17890     etcd   26u  IPv4 160373      0t0  TCP db.master.lan:44406->db.slave.lan:2380 (ESTABLISHED)
etcd     17890     etcd   27u  IPv4 160486      0t0  TCP db.master.lan:2380->db.slave.lan:55324 (ESTABLISHED)
etcd     17890     etcd   28u  IPv4 165755      0t0  TCP db.master.lan:50072->db.etcd.lan:2380 (ESTABLISHED)
etcd     17890     etcd   29u  IPv4 165756      0t0  TCP db.master.lan:50076->db.etcd.lan:2380 (ESTABLISHED)
etcd     17890     etcd   33u  IPv4 165760      0t0  TCP db.master.lan:2380->db.etcd.lan:54206 (ESTABLISHED)
etcd     17890     etcd   34u  IPv4 165762      0t0  TCP db.master.lan:2380->db.etcd.lan:54218 (ESTABLISHED)
etcd     17890     etcd   35u  IPv4 165778      0t0  TCP db.master.lan:50104->db.etcd.lan:2380 (ESTABLISHED)
etcd     17890     etcd   37u  IPv4 165794      0t0  TCP db.master.lan:2380->db.etcd.lan:39058 (ESTABLISHED)
```


Проверка работы.
```bash
etcdctl put mykey "Hello, etcd!"
OK

etcdctl get mykey
mykey
Hello, etcd!

etcdctl endpoint health
127.0.0.1:2379 is healthy: successfully committed proposal: took = 1.693226ms
```

### 5.2. Patroni конфигурация

[Patroni PostgreSQL - Cluster Setup](https://www.youtube.com/watch?v=A_t_ytq1lpA)

Скопировал конфиг, который был представлен в виде примера, после чего переделал его под свои нужды.

```bash
cp -v /etc/patroni/config.yml.in /etc/patroni/config.yml
```

Демон ищет конфиг по этому пути:
```bash
cat /lib/systemd/system/patroni.service | grep -i execstart=

ExecStart=/usr/bin/patroni /etc/patroni/config.yml
```

Создание особого пути для базы данных
```bash
mkdir /var/lib/postgresql/15/data
chown postgres:postgres /var/lib/postgresql/15/data
```

После изменения конфигурации осуществляю проверку:
```bash
patroni --validate-config /etc/patroni/config.yml
```

Занялся сертификацией - создал сертификаты, а после раскидал их на ноды.
```bash
mkdir -p /var/lib/postgresql/ssl

# генерируем ключи для ssl

openssl genrsa -out server.key 2048 # private key
openssl req -new -key server.key -out server.req # csr - реквест для сертификата
openssl req -x509 -key server.key -in server.req -out server.crt -days 3650 # 5 лет
```

После занялся созданием конфигурационного файла **Patroni**.

Параметры **Patroni**, которые я указал в файле:
> блок глобальных параметров
- **scope**: имя моего кластера
- **namespace**: место в конфигурации, где **Patroni** будет хранить информацию о кластере. Дефолтное значение: service
- **name**: имя ноды - на каждой ноде (**MASTER** и **BACKUP**) оно должно быть разное!
--- 
> блок etcd:
- **etcd3**: конфигурация **etcd**. Важно указать версию, иначе в актуальных дистрибутивах работать не станет (там, где пакет и бинарник называются так)!
-  **hosts** - **etcd**-ноды, которые записываются через запятую. Например, 192.168.2.30:2379,192.168.2.40:2379. Порт указывается именно тот, на котором сервер **etcd** слушает клиентов, не другие серверы в своем кластере!
- **protocol** - http или https. В моем случае шифрования нет, поэтому оставляю **http**, которое является дефолтным.
- **cacert**: сертификат **crt**
- **cert**: сертификат.
- **key**: приватный ключ.
---
> restapi блок:
- **restapi**: **Patroni** создает веб-сервис посредством **rest-api**, где определяет, кто является лидером (leader) кластера. Каждая нода в кластере опрашивает, кто является лидером, а кто репликой, с определенной периодичностью.
- **listen**: какие соединения будут слушаться (кто пытается биться к серверу). Указываю, что любые соединения - 0.0.0.0.
- **connect_address**: какой адрес на машине (на которой запущен patroni) будет выбран. Эта та машина, к которой обращаются.
- **certfile**: сертификат для рест-апи, обычно это **pem**.

> dcs(Distributed Configuration Store): 
- **ttl**: время, в течении которого информация о лидере является актуальной, указал 30 сек.
- **loop_wait**: как часто **Patroni** проверяет сам себя. Указал 10 сек.
- **retry_timeout**: время, в течении которого Patroni будет пытаться подсоединиться к утерянному **DCS**, указал 10 сек.
- **max_lag_on_failover**: какая задержка допустима между лидером и репликами, оставил стандартные 1 МБ.
- **check_timeline**: проверка временной линии между нодами.

> initdb
- **encoding**: указал кодировку для инициализации ДБ UTF-8.
- **data-checksums**: проверяет контрольные суммы, чтобы не было фальсификации данных.

> users 

В этом блоке я создал пользователя **cluster**, имеющий права создавать роли и базы данных.

> postgresql
- **listen**: где слушает, указал 0.0.0.0:5050
- **connect_address**: адресом, куда подсоединяются указал адреса нод.
- **data_dir**: рабочей директорией Патрони указал `/var/lib/postgresql/15/data`
- **pg_ctl**: указал местоположение, иначе работать Patroni отказывался, так как искал по другому пути.
- **parameters**: содержание postgresql.conf, указал здесь местоположение сертификатов.

После того, как patroni отрабатывает - он хранит свои файлы, по типу **pg_hba** или **postgresql.conf** по пути **/var/lib/postgresql/data**

Проблема заключалась в том, что **etcd** хранил старые и неактуальные данные, которые остались от неудачных запусков. Поэтому я их удалил командой `etcdctl del "" --prefix`.

После чего инициализация и создание лидера прошли удачно:
```bash
patronictl -c /etc/patroni/config.yml list

+ Cluster: postgres_cluster --+--------+---------+----+-----------+
| Member  | Host              | Role   | State   | TL | Lag in MB |
+---------+-------------------+--------+---------+----+-----------+
| cluster | 192.168.2.16:5050 | Leader | running |  1 |           |
+---------+-------------------+--------+---------+----+-----------+
```

Перезапустил поочередно службы, почистил значения **WAL** у **etcd**. И получил рабочий кластер **Patroni**:

![Pasted image 20250223193840](https://github.com/user-attachments/assets/34520484-c941-4b0c-9f4c-48f0da4fc3a2)

### 5.3. Демонстрация работы и тестирование

Рабочая конфигурация:

![Pasted image 20250223193840](https://github.com/user-attachments/assets/87e0a153-fcce-405d-a6ac-66239c8c45c7)


Узнаем кто лидер, и по какому порту работает **postgres**.
```bash
patronictl -c /etc/patroni/config.yml dsn
host=192.168.2.16 port=5050
```

Просмотр работы кластера:

![Pasted image 20250223194730](https://github.com/user-attachments/assets/e356d337-ba86-4c75-9cec-99fed7b5700f)

Смена лидера на реплику:

![Pasted image 20250223195521](https://github.com/user-attachments/assets/1f80b132-5b70-4624-8068-4c281d523b3f)


Делается это при помощи параметра **failover**.

Подсоединение происходит, 5010 - это порт балансировки, **db.vip.lan** - адрес **VRRP**, **cluster** - пользователь, которого создал сценарий **Patroni**. Шифрование тоже подхватывается.

![Pasted image 20250223215859](https://github.com/user-attachments/assets/bc8b985d-a3fd-45f3-b342-1e68ccaa42b4)

### 5.4. Возникшие проблемы

[etcd-issues/docs/cluster\_id\_mismatch.md at master · ahrtr/etcd-issues · GitHub](https://github.com/ahrtr/etcd-issues/blob/master/docs/cluster_id_mismatch.md)
[Constant request cluster ID mismatch (got X want X) on cluster boot · Issue #12361 · etcd-io/etcd](https://github.com/etcd-io/etcd/issues/12361)
Возникла проблема такого характера на **etcd**

Как оказалось, нужно всегда вычищать содержимое **/var/lib/etcd** или другой рабочей директории для **etcd**, после чего удалять все данные ключ-значение из базы: `etcdctl del "" --prefix`. Только после таких манипуляций у меня все заработало.

![Pasted image 20250222135843](https://github.com/user-attachments/assets/7400bcdf-c57f-4823-b5a8-e20e4fdec042)

Долго не мог разрешить проблему, возникала ошибка такого характера:
```bash
фев 21 13:02:34 dbmaster patroni[15473]:   File "/usr/lib/python3/dist-packages/patroni/postgresql/__init__.py", line 226, in pg_ctl
фев 21 13:02:34 dbmaster patroni[15473]:     return subprocess.call(pg_ctl + ['-D', self._data_dir] + list(args), **kwargs) == 0
фев 21 13:02:34 dbmaster patroni[15473]:            ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
фев 21 13:02:34 dbmaster patroni[15473]:   File "/usr/lib/python3.11/subprocess.py", line 389, in call
фев 21 13:02:34 dbmaster patroni[15473]:     with Popen(*popenargs, **kwargs) as p:
фев 21 13:02:34 dbmaster patroni[15473]:          ^^^^^^^^^^^^^^^^^^^^^^^^^^^
фев 21 13:02:34 dbmaster patroni[15473]:   File "/usr/lib/python3.11/subprocess.py", line 1024, in __init__
фев 21 13:02:34 dbmaster patroni[15473]:     self._execute_child(args, executable, preexec_fn, close_fds,
фев 21 13:02:34 dbmaster patroni[15473]:   File "/usr/lib/python3.11/subprocess.py", line 1901, in _execute_child
фев 21 13:02:34 dbmaster patroni[15473]:     raise child_exception_type(errno_num, err_msg, err_filename)


# то есть patroni не мог найти местоположение бинарника pg_ctl
фев 21 13:02:34 dbmaster patroni[15473]: FileNotFoundError: [Errno 2] No such file or directory: 'pg_ctl'
```

Впоследствии оказалось, что в какой-то момент в **Debian** произошла замена **pg_ctl** на **pg_cluster**:

> Замена pg_ctl
> 
	pg_ctl это команда для управления PostgreSQL из командной строки, которая используется для управления базой данных. Debian имеет Perl-обёртку для pg_ctl, которая вызывается из /usr/bin/pg_ctlcluster. Используйте pg_ctlcluster, когда вам потребуется использовать pg_ctl. Файл настроек находится в /etc/postgresql/[version]/[cluster]/pg_ctl.conf

[pg\_ctl(1) — postgresql-11 — Debian buster — Debian Manpages](https://manpages.debian.org/buster/postgresql-11/pg_ctl.1.en.html)

**Patroni** отказывался запускаться, так как ему не хватало прав, хотя у директории были абсолютно все права, необходимые пользователю **postgres**: 

```bash
 Файлы, относящиеся к этой СУБД, будут принадлежать пользователю "postgres".
фев 21 13:22:02 dbmaster patroni[18845]: От его имени также будет запускаться процесс сервера.
фев 21 13:22:02 dbmaster patroni[18845]: Кластер баз данных будет инициализирован с локалью "ru_RU.UTF-8".
фев 21 13:22:02 dbmaster patroni[18845]: Кодировка БД по умолчанию, выбранная в соответствии с настройками: "UTF8".
фев 21 13:22:02 dbmaster patroni[18845]: Выбрана конфигурация текстового поиска по умолчанию "russian".
фев 21 13:22:02 dbmaster patroni[18845]: Контроль целостности страниц данных отключён.
фев 21 13:22:02 dbmaster patroni[18845]: создание каталога /mnt/postgres_patronidb... initdb: ошибка: не удалось создать каталог "/mnt/postgres_patronidb": Отказано в доступе
фев 21 13:22:02 dbmaster patroni[18841]: pg_ctl: сбой при инициализации системы баз данных
фев 21 13:22:02 dbmaster patroni[18832]: 2025-02-21 13:22:02,057 INFO: removing initialize key after failed attempt to bootstrap the cluster
```

```bash
postgres@dbmaster:/mnt/databases$ ls -l ../
итого 4
drwxr-xr-x 2 postgres postgres 4096 фев 21 13:29 databases
postgres@dbmaster:/mnt/databases$ whoami
postgres
postgres@dbmaster:/mnt/databases$ touch test2
postgres@dbmaster:/mnt/databases$ ls -la
итого 8
drwxr-xr-x 2 postgres postgres 4096 фев 21 13:29 .
drwxr-xr-x 3 root     root     4096 фев 21 13:20 ..
-rw-r--r-- 1 postgres postgres    0 фев 21 13:29 test
-rw-r--r-- 1 postgres postgres    0 фев 21 13:29 test2
```

[pg\_hba.conf not being generated based on the patroni.yml · Issue #2315 · patroni/patroni · GitHub](https://github.com/patroni/patroni/issues/2315)

Проблема заключалась в том, что по сценарию **pg_hba** должен был создаваться в поле **bootstrap**, которое идет после создания **postgresql**, когда никакой БД еще не создано. То есть, пользователь **postgres** не мог подсоединиться к своей БД, так как еще не были созданы правила для этого. Все заработало после того, как я указал правила **pg_hba** в **postgresql**.

### 5.5. PgAdmin

Запустил PgAdmin через docker на ноде db.etcd.lan. Теперь можно попробовать осуществить коннект к БД.

![Pasted image 20250224003600](https://github.com/user-attachments/assets/8ca093e5-f9d8-464c-a605-0fb01c107f53)

192.168.2.17 отображается в роли реплики, как и положено.

![Pasted image 20250224010007](https://github.com/user-attachments/assets/a65310a9-9985-439e-a03a-20a9d0343554)

Все создается, а после реплицируется.

![Pasted image 20250224010257](https://github.com/user-attachments/assets/56882146-2651-4c77-9179-5baac5fb45fd)

## 6. Организация файрвола

Настроил файрвол посредством nftables, открыл все необходимые порты, для остальных сделал дроп пакетов. Также настроил мониторинг параметром `log prefix`, где описал как обозначать пакеты. которые ходят на определенный порт. 
Конфигурационный файл для нод с Patroni выглядит таким образом:

```bash
#!/usr/sbin/nft -f

flush ruleset

table inet myfilter {
        chain allfilter {
                type filter hook input priority filter; policy drop;
                tcp dport 22 log prefix "SSH traffic: " accept
                iifname "lo" accept
                udp dport 53 accept
                tcp dport 53 accept
                ct state established,related accept
                tcp dport { 2379, 2380 } jump etcd
                tcp dport 8888 jump patroni-rest
                tcp dport 5050 log prefix "PostgreSQL: " accept 
        }

        chain etcd {
                tcp dport 2379 log prefix "ETCD Traffic: " accept
                tcp dport 2380 log prefix "ETCD Traffic: " accept
        }

        chain patroni-rest {
                tcp dport 8888 log prefix "Rest-API Patroni: "  accept
        }
}
```

Подобно настроил и для нод **HAProxy**, где открыл порты для проксирования (5001, 5002, 5010) и порт для WEB GUI - 8404. 
 
Теперь в журнале можно мониторить хождения пакетов, c чем нам помогает netfilter:

![image](https://github.com/user-attachments/assets/96b0c5e5-1d28-402d-8a1f-96d277582e06)

Порой это бывает очень удобно для отладки сетевых проблем.

Заодно написал плейбук, который раскидывает файлы с конфигурацией nftables и перезапускает службу:

```yaml
- name: Setup firewall on the postgres machines
  hosts: database
  become: true
  gather_facts: false
  tasks:
    - name: Ensure that nftables package is installed
      ansible.builtin.apt:
        name: nftables
        state: present
        update_cache: true

    - name: Copy files to the machines
      ansible.builtin.copy:
        src: ../../config_files/firewall/psql_nftables.conf
        dest: /etc/nftables.conf
        mode: '0751'
        owner: root
        group: root

    - name: Start and enable nftables service
      ansible.builtin.service:
        name: nftables
        state: restarted
        enabled: true
```

Подобно описал и для **HAProxy** нод.

## 7. Организация автоматического бэкапирования

### 7.1. Бэкапы БД PostgreSQL

Для отказоустойчивости и сохранности данных в БД важно всегда иметь копии данных. Еще лучше будет настроить осуществление копирования автоматически на другую ноду. В качестве инструментов для  организации бэкапирования я выбрал **pgBackRest** для данных **PostgresSQL** и **Restic** для копирования содержания всей корневой файловой системы **db.master.lan**. 

Заодно **Restic** будет работать и на **db.test.lan**, копируя все содержимое корневой файловой системы. Таким образом, будет осуществляться сохранность ФС нод **Haproxy** и Мастер-ноды кластера **Patroni**.

Хранение бэкапов будет осуществляться на ноде **db.etcd.lan**, создам директорию для хранения бэкапов **PostgreSQL**:
```bash
mkdir /mnt/pgbackrest_backups
chown postgres:postgres -R /mnt/pgbackrest_backups
```

Так же важно подправить конфигурацию **Patroni**, добавив в качестве бэкапера **pgBackRest**. 
```bash
postgresql:
	parameters:
		archive__command: pgbackrest --stanza=testcluster1 archive-push "%p"
		archive_mode: on
		max_wal_senders: 3
```

Устанавливаю:
```bash
apt install pgbackrest
```

Конфигурация **pgBackRest** будет находиться на **Мастер** ноде:
```bash
# my stanza:
[testcluster]
testcluster1-path=/var/lib/postgresql/15/data

[global]
repo1-path=/mnt/pgbackrest_backups
repo1-sftp-host=db.etcd.lan
repo1-sftp-host-user=postgres
repo1-sftp-private-key-file=/var/lib/postgresql/.ssh/id_rsa
repo1-sftp-public-key-file=/var/lib/postgresql/.ssh/id_rsa.pub
repo1-type=sftp
repo1-retention-full=2
repo1-retention-diff=2
repo1-cipher-pass=gOBeYCo1abkbbxMZAaOIrN3u1flD446W7T+Im+tzYwLq0QYurVAUBF9huKXpiYsP
repo1-cipher-type=aes-256-cbc

start-fast=y
```

После того, как я инициализировал репозиторий (stanza), то осуществил бэкап:
```bash
sudo -u postgres pgbackrest --stanza=testluster --log-level-console=info backup
```

После бэкапа проверяем состояние:
```bash
pgbackrest info

stanza: testcluster
    status: ok
    cipher: aes-256-cbc

    db (current)
        wal archive min/max (15): 000000010000000000000001/0000000B000000000000000F

        full backup: 20250228-094415F
            timestamp start/stop: 2025-02-28 09:44:15+03 / 2025-02-28 09:44:34+03
            wal start/stop: 0000000B000000000000000F / 0000000B000000000000000F
            database size: 29.3MB, database backup size: 29.3MB
            repo1: backup set size: 3.9MB, backup size: 3.9MB
```

Теперь добавим в **cron** команды, которые будут исполняться следующим образом:
```bash
30 18 * * 0    pggackrest --type=full --stanza=testcluster backup
30 18 * * 1-6  pgbackrest --type=diff --stanza=testcluster backup
30 09 * * 1-6  pbbackrest --type=incr --stanza=testcluster backup
```
Теперь по воскресенья будет делаться полный бэкап, с понедельника по субботу дифференциальный и инкрементальный бэкапы.

Останавливаем кластер **Patroni** и пробуем осуществить восстановление данных:
```bash
sudo -u postgres pgbackrest --delta --stanza=testcluster --log-level-console=info restore
2025-02-28 10:08:07.740 P00   INFO: restore command begin 2.54.2: --delta --exec-id=460584-e4890abf --log-level-console=info --pg1-path=/var/lib/postgresql/15/data --process-max=4 --repo1-cipher-pass=<redacted> --repo1-cipher-type=aes-256-cbc --repo1-path=/mnt/pgbackrest_backups --repo1-sftp-host=db.etcd.lan --repo1-sftp-host-key-hash-type=sha1 --repo1-sftp-host-user=postgres --repo1-sftp-private-key-file=/var/lib/postgresql/.ssh/id_ed25519 --repo1-sftp-public-key-file=/var/lib/postgresql/.ssh/id_ed25519.pub --repo1-type=sftp --stanza=testcluster
2025-02-28 10:08:08.046 P00   INFO: repo1: restore backup set 20250228-094415F, recovery will start at 2025-02-28 09:44:15
2025-02-28 10:08:08.128 P00   INFO: remove invalid files/links/paths from '/var/lib/postgresql/15/data'
2025-02-28 10:08:09.110 P00   INFO: write updated /var/lib/postgresql/15/data/postgresql.auto.conf
2025-02-28 10:08:09.770 P00   INFO: restore global/pg_control (performed last to ensure aborted restores cannot be started)
2025-02-28 10:08:09.862 P00   INFO: restore size = 29.3MB, file total = 1273
```

Все прошло удачно, теперь бэкапы БД будут происходить автоматически, записываться они будут на `db.etcd.lan`. 

После написал плейбук, который настраивает и запускает **pgBackRest**. При помощи него происходит инициализация репозитория, создание `stanza`, после чего запускается создание бэкапа. Результат следующий:

![Pasted image 20250301124809](https://github.com/user-attachments/assets/25ddd06e-f3b3-4b28-9b79-311d566aa40a)

Как видно по скриншоту, создаются, в том числе и джобы **cron**.

### 7.2. Бэкап всей корневой файловой системы

Помимо того, что можно делать снэпшоты виртуальных машин, посредством, например, **Proxmox** или **VMware ESXi**, что уже обеспечивает неплохой уровень сохранности данных, особенно если снимок хранится на другом диске, почти всегда используют множество дисков, которые объединены в Raid-массивы, **RAID 5** или **RAIDZ**. Пока жестких диска у меня два, поэтому формирование пятого рэйда невозможно, а первого нецелесообразно, так как много места уходит на зеркалирование.

Решением является снимок всей ФС такими инструментами, как **Restic** или **rsync**. Далее я буду использовать связку **Restic** и **Rclone**, чтобы делать снэпшот мастер-ноды **Patroni** и хранить его на `db.etcd.lan`.


Устанавливаю: `apt install -y restic rclone`

Так же огромным плюсом и удобством такого подхода является возможность восстановить единичные файлы из репозитория **Restic**. Если, по ошибке, был удален важный конфигурационный файл или он затерся при обновлении софта, то восстановить его будет достаточно легко.

Создадим конфиг, к которому обращается **rclone**:
```bash
mkdir /root/.config/rclone/ && touch /root/.config/rclone/rclone.conf
```
Для начала настроим rclone для передачи данных по **sftp**:

```bash
[etcd-serv]
type = sftp
host = db.etcd.lan
user = root
port = 22
key_file = /var/lib/postgresql/.ssh/id_ed25519
key_use_agent = false
shell_type = unix
md5sum_command = md5sum
sha1sum_command = sha1sum
```

Проверяем:
```bash
root@dbmaster:~/.config/rclone# rclone lsd etcd-serv:/ 
          -1 2025-02-28 09:46:13        -1 bin
          -1 2025-02-18 15:39:42        -1 boot
          -1 2025-02-25 21:50:11        -1 dev
          -1 2025-02-26 14:19:29        -1 etc
          -1 2025-02-24 00:20:45        -1 home
          -1 2025-02-24 00:23:31        -1 lib
          -1 2025-02-18 14:22:08        -1 lib64
          -1 2025-02-18 14:21:23        -1 lost+found
          -1 2025-02-18 14:21:23        -1 media
          -1 2025-02-27 16:41:35        -1 mnt
          -1 2025-02-24 00:23:45        -1 opt
          -1 2025-02-25 21:50:00        -1 proc
          -1 2025-03-01 13:23:22        -1 root
          -1 2025-03-01 13:23:28        -1 run
          -1 2025-02-25 15:40:24        -1 sbin
          -1 2025-02-18 14:21:40        -1 srv
          -1 2025-02-25 21:50:00        -1 sys
          -1 2025-03-01 12:46:07        -1 tmp
          -1 2025-02-18 14:21:40        -1 usr
          -1 2025-02-18 14:21:40        -1 var
```

Все работает, **sftp**-соединение c `db.etcd.lan` работает.

Инициализируем репозиторий для хранения у **restic**:
```bash
root@dbmaster:/mnt# restic -r rclone:etcd-serv:/mnt/restic_backups init
enter password for new repository: 
enter password again: 
created restic repository 4a2d44efd9 at rclone:etcd-serv:/mnt/restic_backups

Please note that knowledge of your password is required to access
the repository. Losing your password means that your data is
irrecoverably lost.
```

Теперь можно делать бэкап:
```bash
 restic -r rclone:etcd-serv:/mnt/restic_backups backup --tag master_node_patroni --one-file-system --skip-if-unchanged / 
```

И проверить то, что снэпшот создался:
```bash
restic -r rclone:etcd-serv:/mnt/restic_backups snapshots
enter password for repository: 
repository 4a2d44ef opened (version 2, compression level auto)
ID        Time                 Host        Tags                 Paths  Size
--------------------------------------------------------------------------------
7a675871  2025-03-01 13:39:12  dbmaster    master_node_patroni  /      6.499 GiB
--------------------------------------------------------------------------------
1 snapshots
```

Создадим службу и таймер:
1. `touch /etc/systemd/system/restic.service`
2. `touch /etc/systemd/system/restic.timer`

Служба выглядит так:
```bash
[Unit]
Description=Restic backup for Patroni Main Node
After=syslog.target
After=network-online.target

[Service]
Type=oneshot
User=root
ExecStart=/usr/bin/restic -r rclone:etcd-serv:/mnt/restic_backups backup / --tag master_node_patroni --one-file-system --skip-if-unchanged --verbose=2 
EnvironmentFile=/root/.restic.env
AmbientCapabilities=CAP_DAC_READ_SEARCH

[Install]
WantedBy=multi-user.target
```

Создал плейбук, который создает репозиторий **Restic**, создает таймер systemd, после чего делает бэкап всей корневой ФС.

![Pasted image 20250301153804](https://github.com/user-attachments/assets/d36c3957-641c-4214-a791-69d0ca879fc7)

## 8. Шифрование 

Для лучшей безопасности решил сделать сертификаты, чтобы соединение между нодами кластера нельзя было скомпрометировать извне. 

Создал центр сертификации, а после и ключи, небольшим скриптом раскидал все файлы на нужные ноды посредством **scp**.

Скрипт создания ключей выглядит следующим образом. Сначала создаю центр сертификации, раскидываю полученные файлы по директориям:

```bash
openssl genrsa -out ca.key 2048
openssl req -x509 -new -nodes -key ca.key -subj "/CN=etcd-ca" -days 7300 -out ca.crt

for dir in ../etcd-node ../master-node ../slave-node; do
cp -v {ca.crt,ca.key} "$dir"
done
```

После чего генерирую публичные и приватные ключи:
```bash
# Generate a private key
openssl genrsa -out etcd-node1.key 2048

# Create temp file for config
cat > temp.cnf <<EOF
[ req ]
distinguished_name = req_distinguished_name
req_extensions = v3_req
[ req_distinguished_name ]
[ v3_req ]
subjectAltName = @alt_names
[ alt_names ]
IP.1 = 192.168.2.18
IP.2 = 127.0.0.1
EOF

# Create a csr
openssl req -new -key etcd-node1.key -out etcd-node1.csr \
-subj "/C=US/ST=YourState/L=YourCity/O=YourOrganization/OU=YourUnit/CN=etcd-node1" \
-config temp.cnf

#Sign the cert
openssl x509 -req -in etcd-node1.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
-out etcd-node1.crt -days 7300 -sha256 -extensions v3_req -extfile temp.cnf

# Verify the cert and be sure you see Subject Name Alternative
openssl x509 -in etcd-node1.crt -text -noout | grep -A1 "Subject Alternative Name"

# Remove temp file
rm temp.cnf
# Create directory for storing
ssh etcd "mkdir -p /etc/etcd/etcd-certs/"

# Copy files
scp ./etcd-node* ca.crt etcd:/etc/etcd/etcd-certs/

ssh etcd "chown etcd:etcd -R /etc/etcd/"

# Give writes to postgres user read key file
ssh etcd "chown etcd:etcd -R /etc/etcd/"

ssh etcd "chmod 640 /etc/etcd/etcd-certs/*.key"
ssh etcd "ls -l /etc/etcd/etcd-certs/*.key"

``` 

Такие же скрипты сделал для `db.master.lan` и `db.slave.lan`, поменяв **IP.1**. 

![Pasted image 20250302161308](https://github.com/user-attachments/assets/bf9b2776-e585-46f9-a8f1-9d5955ce94eb)

После перезапустил кластер **etcd** и получил шифрование трафика (как и **peer**, так и **client**).
```bash
root@etcd:~# etcdctl   --endpoints=https://192.168.2.16:2379,https://192.168.2.17:2379,https://192.168.2.18:2379   --cacert=/etc/etcd/etcd-certs/ca.crt   --cert=/etc/etcd/etcd-certs/etcd-node1.crt   --key=/etc/etcd/etcd-certs/etcd-node1.key   endpoint status --write-out=table
+---------------------------+------------------+---------+---------+-----------+------------+-----------+------------+--------------------+--------+
|         ENDPOINT          |        ID        | VERSION | DB SIZE | IS LEADER | IS LEARNER | RAFT TERM | RAFT INDEX | RAFT APPLIED INDEX | ERRORS |
+---------------------------+------------------+---------+---------+-----------+------------+-----------+------------+--------------------+--------+
| https://192.168.2.16:2379 | 671c408bce8fb03c |  3.5.16 |   20 kB |     false |      false |         3 |          9 |                  9 |        |
| https://192.168.2.17:2379 |  b6d4fe4f3346acb |  3.5.16 |   20 kB |     false |      false |         3 |          9 |                  9 |        |
| https://192.168.2.18:2379 | feb950520d2b15b7 |  3.4.23 |   20 kB |      true |      false |         3 |          9 |                  9 |        |
+---------------------------+------------------+---------+---------+-----------+------------+-----------+------------+--------------------+--------+
root@etcd:~# etcdctl   --endpoints=https://192.168.2.16:2379,https://192.168.2.17:2379,https://192.168.2.18:2379   --cacert=/etc/etcd/etcd-certs/ca.crt   --cert=/etc/etcd/etcd-certs/etcd-node1.crt   --key=/etc/etcd/etcd-certs/etcd-node1.key  member list --write-out=table
+------------------+---------+----------+---------------------------+---------------------------+------------+
|        ID        | STATUS  |   NAME   |        PEER ADDRS         |       CLIENT ADDRS        | IS LEARNER |
+------------------+---------+----------+---------------------------+---------------------------+------------+
|  b6d4fe4f3346acb | started |  slavepg | https://192.168.2.17:2380 | https://192.168.2.17:2379 |      false |
| 671c408bce8fb03c | started | masterpg | https://192.168.2.16:2380 | https://192.168.2.16:2379 |      false |
| feb950520d2b15b7 | started |   etcdpg | https://192.168.2.18:2380 | https://192.168.2.18:2379 |      false |
+------------------+---------+----------+---------------------------+---------------------------+------------+
root@etcd:~# etcdctl   --endpoints=https://192.168.2.16:2379,https://192.168.2.17:2379,https://192.168.2.18:2379   --cacert=/etc/etcd/etcd-certs/ca.crt   --cert=/etc/etcd/etcd-certs/etcd-node1.crt   --key=/etc/etcd/etcd-certs/etcd-node1.key  endpoint health --write-out=table
+---------------------------+--------+-------------+-------+
|         ENDPOINT          | HEALTH |    TOOK     | ERROR |
+---------------------------+--------+-------------+-------+
| https://192.168.2.18:2379 |   true | 27.631485ms |       |
| https://192.168.2.17:2379 |   true | 27.194669ms |       |
| https://192.168.2.16:2379 |   true | 31.394881ms |       |
+---------------------------+--------+-------------+-------+
```

Создал скрипт, который создает **PEM**-файл, в котором будет сразу и ключ, и сертификат (это необходимо для Rest-API Patroni):
```bash
ssh masterdb "sudo sh -c 'cat /var/lib/postgresql/15/ssl/cluster.crt /var/lib/postgresql/15/ssl/cluster.key > /var/lib/postgresql/15/ssl/cluster.pem'"
ssh masterdb "sudo chown postgres:postgres /var/lib/postgresql/15/ssl/cluster.pem"
ssh masterdb "sudo chmod 600 /var/lib/postgresql/15/ssl/cluster.pem"
```

Теперь у Rest-API Patroni есть шифрование, при curl-запросе попытки подсоединиться по http будут отбрасываться.
## 9. Мысли по улучшению

1. Создавать и раннить ВМ не только средствами самого **Proxmox**, что не совсем удобно и быстро, а используя более подходящие инструменты. Допустим, **Terraform**, и в качестве провайдера к нему тот же **Proxmox** или любой другой инструмент с гипервизором. Как альтернативу, еще можно использовать голый **Alpine** **Linux** или легковесный **Debian** в **Docker** (и уже все настроить там), после чего запустить.
2. ~~Настроить файрвол нод **Postgres** и **HAProxy** посредством **nftables** (безопасность).~~ 
3. ~~Заняться сертификатами, самоподписные (**openssl**) более чем подойдут, чтобы трафик и со стороны **etcd** <-> **db slave** был защищен, и **haproxy** <->  **db** **cluster**, а также **rest-api** **Patroni**. Иначе трафик может сниффиться, после чего дампиться тем же **tcpdump** и прочитываться, что крайне небезопасно. `serving insecure client requests on [::]:2379, this is strongly discouraged!` - **etcd** даже возмущается небезопасному соединению.~~
4. ~~Вынести **etcd** на отдельную ноду, а лучше на несколько, чтобы предоставить еще большую **high availability**. Желательно таких нод **etcd** иметь от двух.~~
5. ~~Так же из новой ноды, на которой будет запущен еще один **etcd**, можно сделать бэкапера, который будет копировать всю ФС мастера, например, посредством **restic**.~~ 
