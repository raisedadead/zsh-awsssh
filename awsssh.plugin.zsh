#!/usr/bin/env zsh
# aws-ssh.plugin.zsh

# Check for required commands
required_cmds=(bat awk fzf aws rg tmux)
for cmd in $required_cmds; do
  if ! command -v $cmd &>/dev/null; then
    echo "AWSSSH:INFO: Missing required tool: $cmd"
    exit 1
  fi
done

# Check for AWS credentials
_aws_check_credentials() {
  if [[ -z "$AWS_PROFILE" && -z "$(aws sts get-caller-identity)" ]]; then
    echo "AWSSSH:INFO: AWS credentials not found. Please set AWS_PROFILE or run 'aws configure'."
    return 1
  fi
}

# Query AWS EC2 instances
_aws_query_for_instances() {
  local region=$1 tag_key=$2 tag_value=$3

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

# Handle SSH connection
_aws_ssh_command() {
  local selection=$1 connection=$2 username=$3
  local name=$(echo $selection | awk '{print $1}')
  local public_dns=$(echo $selection | awk '{print $8}')
  local instance_id=$(echo $selection | awk '{print $2}')
  local instance_status=$(echo $selection | awk '{print $5}')

  if [[ "$instance_status" != "running" ]]; then
    echo "AWSSSH:INFO: Instance $name ($instance_status) is not running."
    return 1
  fi

  if [[ "$connection" == "ssh" && -n "$public_dns" ]]; then
    echo "AWSSSH:INFO: Connecting to $name ($public_dns)..."
    ssh $username@$public_dns
  elif [[ "$connection" == "ssm" && -n "$instance_id" ]]; then
    echo "AWSSSH:INFO: Connecting to $name ($instance_id) over SSH using AWS SSM..."
    ssh -o ProxyCommand="aws ssm start-session --target %h --document-name AWS-StartSSHSession --parameters portNumber=%p" $username@$instance_id
  else
    echo "AWSSSH:INFO: Unable to connect to $name ($instance_id) with $connection."
  fi
}

# Launch connections directly as windows in the asw_ssh session
_launch_connections() {
  local selections="$1"
  local connection="$2"
  local username="$3"

  # Ensure the asw_ssh session exists
  tmux has-session -t "asw_ssh" 2>/dev/null || tmux new-session -d -s "asw_ssh"

  while IFS= read -r selection; do
    local name=$(echo $selection | awk '{print $1}')
    local instance_id=$(echo $selection | awk '{print $2}')
    local window_name="ssh:${name}:${instance_id}"

    # Check if the window already exists in the asw_ssh session
    if ! tmux list-windows -t "asw_ssh" | grep -q "$window_name"; then
      # Create the window directly in the asw_ssh session
      tmux new-window -d -n "$window_name" -t "asw_ssh" \
        "zsh -c 'source $HOME/.zshrc; _aws_ssh_command \"$selection\" \"$connection\" \"$username\"; zsh'"
    else
      echo "AWSSSH:ERROR: Window $window_name already exists."
    fi
  done <<< "$selections"

  # Optionally, switch to the asw_ssh session. Remove this line if not needed.
  tmux attach-session -t "asw_ssh"
}

# Main function
_aws_ssh_main() {
  _aws_check_credentials || return 1

  local region=$(aws configure get region) tag_key="Name" tag_value="*" connection="ssm" username="ec2-user"

  local initial_argc=$# # Store the initial number of arguments

  # Parse command-line arguments
  for arg in "$@"; do
    case $arg in
    --region=*)
      region="${arg#*=}"
      shift
      ;;
    --tag-key=*)
      tag_key="${arg#*=}"
      shift
      ;;
    --tag-value=*)
      tag_value="${arg#*=}"
      shift
      ;;
    --connection=*)
      connection="${arg#*=}"
      shift
      ;;
    --username=*)
      username="${arg#*=}"
      shift
      ;;
    *)
      # Unknown option
      echo "Unknown option: $arg"
      return 1
      ;;
    esac
  done

  # If parameters are not passed in the command line, prompt for them
  if [[ $initial_argc -eq 0 ]]; then # Use the initial number of arguments here
    read "?Enter AWS region [$region]: " input_region
    region=${input_region:-$region}

    read "?Enter tag key [$tag_key]: " input_tag_key
    tag_key=${input_tag_key:-$tag_key}

    read "?Enter tag value [$tag_value]: " input_tag_value
    tag_value=${input_tag_value:-$tag_value}

    read "?Enter connection type (ssh/ssm) - [$connection]: " input_connection
    connection=${input_connection:-$connection}

    read "?Enter username [ec2-user]: " input_username
    username=${input_username:-username}
  fi

  local selections=$(
    _aws_query_for_instances "$region" "$tag_key" "$tag_value" |
      fzf \
        --height=40% \
        --layout=reverse \
        --border \
        --border-label="EC2 Instances" \
        --info=default \
        --multi \
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

  if [[ -z "$selections" ]]; then
    echo "AWSSSH:INFO: No instances selected. Exiting..."
    return 1
  fi

  _launch_connections "$selections" "$connection" "$username"
}

alias sshaws='_aws_ssh_main'
alias awsssh='_aws_ssh_main'
alias awsssm='_aws_ssh_main'
