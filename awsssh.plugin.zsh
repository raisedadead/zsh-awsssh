#!/usr/bin/env zsh
# aws-ssh.plugin.zsh

# Check for required commands
for cmd in bat awk fzf aws rg tmux; do
  if ! command -v $cmd &>/dev/null; then
    echo "AWSSSH:INFO: Missing required tool: $cmd"
    exit 1
  fi
done

# Check for credentials with AWS_PROFILE, and/or aws sts get-caller-identity
_aws_check_credentials() {
  if [[ -z "$AWS_PROFILE" || -z "$(aws sts get-caller-identity)" ]]; then
    echo "AWSSSH:INFO: AWS credentials not found. Please set AWS_PROFILE or run 'aws sso configure', 'aws sso login', etc. as needed."
    return 1
  fi
}

_aws_query_for_instances() {
  local region=$1
  local tag_key=$2
  local tag_value=$3

  # Correctly print header with specified order
  printf "%-30s\t%-20s\t%-15s\t%-15s\t%-15s\t%-20s\t%-10s\t%s\n" "Name" "Instance ID" "Private IP" "Public IP" "Status" "AMI" "Type" "Public DNS Name"

  aws ec2 describe-instances \
    --region "$region" \
    --filters Name=tag:$tag_key,Values="$tag_value" \
    --query 'Reservations[*].Instances[*].[Tags[?Key==`Name`].Value | [0], InstanceId, PrivateIpAddress, PublicIpAddress, State.Name, ImageId, InstanceType, PublicDnsName]' \
    --output text |
    rg -v '^None$' |
    # Ensure awk prints fields in the correct order
    awk '{printf "%-30s\t%-20s\t%-15s\t%-15s\t%-15s\t%-20s\t%-10s\t%s\n", $1, $2, $3, $4, $5, $6, $7, $8}'
}

_aws_ssh_command() {
  local selection=$1
  local connection=$2
  local username=$3

  local name=$(echo $selection | awk '{print $1}')
  local public_dns=$(echo $selection | awk '{print $8}')
  local instance_id=$(echo $selection | awk '{print $2}')
  local instance_status=$(echo $selection | awk '{print $5}')

  if [[ "$instance_status" != "running" ]]; then
    echo "AWSSSH:INFO: Instance $name is not running. Current status: $instance_status"
    return 1
  fi

  if [[ "$connection" == "ssh" && -n "$public_dns" ]]; then
    echo "AWSSSH:INFO: Connecting to $name with the dns: $public_dns..."
    ssh "$username@$public_dns"
  elif [[ "$connection" == "ssm" && -n "$instance_id" ]]; then
    echo "AWSSSH:INFO: Connecting to $name with the instance id: $instance_id... over SSH using AWS SSM as a proxy."
    ssh -o ProxyCommand='aws ssm start-session --target %h --document-name AWS-StartSSHSession --parameters portNumber=%p' "$username@$instance_id"
  else
    echo "AWSSSH:INFO: Unable to connect to instance $name - $instance_id with connection type $connection."
  fi
}

_aws_ssh_main() {

  _aws_check_credentials || return 1

  local default_region=$(aws configure get region)
  local default_tag_key="Name"
  local default_tag_value="*"
  local default_connection="ssh"

  read "?Enter AWS region [$default_region]: " region
  region=${region:-$default_region}

  read "?Enter tag key [$default_tag_key]: " tag_key
  tag_key=${tag_key:-$default_tag_key}

  read "?Enter tag value [$default_tag_value]: " tag_value
  tag_value=${tag_value:-$default_tag_value}

  read "?Enter connection type (ssm/ssh) - [$default_connection]: " connection
  connection=${connection:-$default_connection}

  local selections=$(
    _aws_query_for_instances "$region" "$tag_key" "$tag_value" |
      fzf \
        --height=40% \
        --layout=reverse \
        --border \
        --border-label="EC2 Instances" \
        --info=default \
        --prompt="Search Instance: " \
        --header="Select (Enter), Toggle Details (Ctrl-/), Quit (Ctrl-C or ESC)" \
        --header-lines=1 \
        --bind="ctrl-/:toggle-preview" \
        --preview-window="right:40%:wrap" \
        --preview-label="Details" \
        --preview='
        echo {} |
        awk -F"\t" "{
          print \"Name: \" \$1 \"\\nInstance ID: \" \$2 \"\\nPrivate IP: \" \$3 \"\\nPublic IP: \" \$4 \"\\nStatus: \" \$5 \"\\nAMI: \" \$6 \"\\nType: \" \$7 \"\\nPublic DNS Name: \" \$8
        }"
        ' \
        --delimiter=$'\t' \
        --with-nth=1,2,3,4,5
  )

  read "?Enter username [ec2-user]: " username
  username=${username:-ec2-user}

  _aws_ssh_command "$selections" "$connection" "$username"
}

alias sshaws='_aws_ssh_main'
alias awsssh='_aws_ssh_main'
alias awsssm='_aws_ssh_main'
