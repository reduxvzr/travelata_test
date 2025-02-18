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
        mkdir -p /home/*/.ssh &&
        touch /home/*/.ssh/authorized_keys &&
        echo 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIO91EHWdaQCtR/0uX5u//MzTZd5OACiwcsu3fzvuswrF digitd@DESKTOP-BP8SOQ1' >> /home/*/.ssh/authorized_keys &&
        echo $pass | sudo -S systemctl restart ssh
    "
done
