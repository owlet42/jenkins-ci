#! /bin/bash
DIR=$(dirname $0)
source ${DIR}/const.sh

# Get distribution
get_dist_name()
{
  if grep -Eqii "CentOS" /etc/issue || grep -Eq "CentOS" /etc/*-release; then
        dist_name='CentOS'
  elif grep -Eqi "Fedora" /etc/issue || grep -Eq "Fedora" /etc/*-release; then
        dist_name='Fedora'
  elif grep -Eqi "Debian" /etc/issue || grep -Eq "Debian" /etc/*-release; then
        dist_name='Debian'
  elif grep -Eqi "Ubuntu" /etc/issue || grep -Eq "Ubuntu" /etc/*-release; then
        dist_name='Ubuntu'
  else
        dist_name='Unknown'
  fi
  echo $DISTRO;
}

centos()
{
  yum remove docker docker-client docker-client-latest docker-common docker-latest docker-latest-logrotate docker-logrotate docker-engine
  yum install -y yum-utils
  yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
  yum erase podman buildah
  yum install -y docker-ce docker-ce-cli containerd.io
  systemctl start docker
}

fedora()
{
  dnf remove docker docker-client docker-client-latest docker-common docker-latest docker-latest-logrotate docker-logrotate docker-selinux docker-engine-selinux docker-engine
  dnf -y install dnf-plugins-core
  dnf config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo
  dnf install -y docker-ce docker-ce-cli containerd.io
  systemctl start docker
}

debian()
{
  apt-get remove docker docker-engine docker.io containerd runc
  apt-get update
  apt-get install -y apt-transport-https ca-certificates curl gnupg-agent software-properties-common
  curl -fsSL https://download.docker.com/linux/debian/gpg | apt-key add -
  add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/debian $(lsb_release -cs) stable"
  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io
}

ubuntu()
{
  apt-get remove docker docker-engine docker.io containerd runc
  apt-get update
  apt-get install -y \
    apt-transport-https \
    ca-certificates \
    curl \
    gnupg-agent \
    software-properties-common

  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -

  add-apt-repository \
   "deb [arch=amd64] https://download.docker.com/linux/ubuntu \
   $(lsb_release -cs) \
   stable"
  apt-get update
  # apt-get install -y docker-ce docker-ce-cli containerd.io
  version=`5:20.10.2~3-0~ubuntu-bionic`
  apt-get install docker-ce=$version docker-ce-cli=$version containerd.io
}

install_separately()
{
  # Install Docker with different linux distibutions
  get_dist_name
  if [ $dist_name != "Unknown" ]; then
    case $dist_name in
      CentOS)
        centos
        ;;
      Fedora)
        fedora
        ;;
      Debian)
        debian
        ;;
      Ubuntu)
        ubuntu
        ;;
      *)
        echo "Unsupported distribution name"
    esac
  else
    echo "Fatal: Unknown system version"
    exit 1
  fi
}

clean()
{
  if [ -d $DEPLOY_DIR ]; then
    rm -rf $DEPLOY_DIR
  fi
  rm ${DEPLOY_SCRIPT} && rm ${OUT_PUT}
  rm -rf ${BASE_DIR}/ansible*

  echo "Deleting kind cluster..." 
  kind delete cluster
}

trap 'onCtrlC' INT
function onCtrlC () {
  echo 'Ctrl+C is captured'
  clean
}

main()
{
  cd $DEPLOY_DIR
  # Download KubeFATE Release Pack, KubeFATE Server Image v1.2.0 and Install KubeFATE Command Lines
  curl -LO https://github.com/FederatedAI/KubeFATE/releases/download/${version}/kubefate-k8s-${version}.tar.gz && tar -xzf ./kubefate-k8s-${version}.tar.gz

  # Move the kubefate executable binary to path,
  chmod +x ./kubefate && mv ./kubefate /usr/bin

  # Download the KubeFATE Server Image
  curl -LO https://github.com/FederatedAI/KubeFATE/releases/download/${version}/kubefate-${kubefate_version}.docker

  # Load into local Docker
  docker load < ./kubefate-v1.2.0.docker

  # Create kube-fate namespace and account for KubeFATE service
  kubectl apply -f ./rbac-config.yaml
  # kubectl apply -f ./kubefate.yaml

  # Because the Dockerhub latest limitation, I suggest using 163 Image Repository instead.
  sed 's/mariadb:10/hub.c.163.com\/federatedai\/mariadb:10/g' kubefate.yaml > kubefate_163.yaml
  sed 's/registry: ""/registry: "hub.c.163.com\/federatedai"/g' cluster.yaml > cluster_163.yaml
  kubectl apply -f ./kubefate_163.yaml

  # Check the commands above have been executed correctly
  state=`kubefate version`
  if [ $? -ne 0 ]; then
    echo "Fatal: There is something wrong with the installation of kubefate, please check"
    exit 1
  fi

  # Install two fate parties: fate-9999 and fate-10000
  kubectl create namespace fate-9999
  kubectl create namespace fate-10000

  # Copy the cluster.yaml sample in the working folder. One for party 9999, the other one for party 10000
  # cp ./cluster.yaml fate-9999.yaml && cp ./cluster.yaml fate-10000.yaml
cat > fate-9999.yaml << EOF
name: fate-9999
namespace: fate-9999
chartName: fate
chartVersion: v1.5.0
partyId: 9999
registry: "hub.c.163.com/federatedai"
pullPolicy:
persistence: false
istio:
  enabled: false
modules:
  - rollsite
  - clustermanager
  - nodemanager
  - mysql
  - python
  - fateboard
  - client

backend: eggroll

rollsite:
  type: NodePort
  nodePort: 30091
  partyList:
  - partyId: 10000
    partyIp: ${ip}
    partyPort: 30101

python:
  type: NodePort
  httpNodePort: 30097
  grpcNodePort: 30092
EOF

cat > fate-10000.yaml << EOF
name: fate-10000
namespace: fate-10000
chartName: fate
chartVersion: v1.5.0
partyId: 10000
registry: "hub.c.163.com/federatedai"
pullPolicy:
persistence: false
istio:
  enabled: false
modules:
  - rollsite
  - clustermanager
  - nodemanager
  - mysql
  - python
  - fateboard
  - client

backend: eggroll

rollsite:
  type: NodePort
  nodePort: 30101
  partyList:
  - partyId: 9999
    partyIp: ${ip}
    partyPort: 30091

python:
  type: NodePort
  httpNodePort: 30107
  grpcNodePort: 30102
EOF

  # Start to install these two FATE cluster via KubeFATE with the following command
  echo "Waiting for kubefate service start to create container..."
  sleep ${time_out}

  selector_kubefate="fate=kubefate"
  kubectl wait --namespace kube-fate \
  --for=condition=ready pod \
  --selector=${selector_kubefate} \
  --timeout=3600s

  selector_mariadb="fate=mariadb"
  kubectl wait --namespace kube-fate \
  --for=condition=ready pod \
  --selector=${selector_mariadb} \
  --timeout=3600s

  echo "Waiting for kubefate service get ready..."
  time_out=600
  i=0
  kubefate_status=`kubefate version`
  while [ $? -ne 0 ]
  do
    if [ $i == $time_out ]; then
        echo "Can't install Ingress, Please check you environment"
        exit 1
    fi
    echo "Kubefate  Service Temporarily Unavailable, please wait..."
    sleep 1
    let i+=1
    kubefate_status=`kubefate version`
  done
  kubefate cluster install -f ./fate-9999.yaml
  kubefate cluster install -f ./fate-10000.yaml
  kubefate cluster ls

  # Clean working directory
  clean
}

main
