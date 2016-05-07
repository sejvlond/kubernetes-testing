# Kubernetes support testing scripts

Create kubernetes cluster with flannel network

on master install docker and run with root privileges
```
export MASTER_IP=`hostname -I | awk '{print $1}'`
./kube.sh start-master
```

on each worker node
```
export MASTER_IP=###YOUR#MUSTER#IP###
./kube.sh start-worker
```

then download `kubectl` and start creating pods and servicies, ...

## Tarsier
Tarsier configuration is stored in text files and with `tarsier/conf2secrets.sh`
script all secrets can be generated
