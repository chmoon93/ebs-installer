# Install AWS EBS CSI Driver

## Prerequisites

- [awscli v2](https://docs.aws.amazon.com/ko_kr/cli/latest/userguide/install-cliv2.html)
- [kubectl](https://docs.aws.amazon.com/ko_kr/eks/latest/userguide/install-kubectl.html)
- [jq](https://stedolan.github.io/jq/download/)
- [helm v3](https://helm.sh/ko/docs/intro/install/)
- [curl](https://curl.se/download.html)

## Usage

### Install

```shell
./ebs_csi_installer.sh
```

### Cleanup

```shell
./ebs_csi_installer.sh delete
```
