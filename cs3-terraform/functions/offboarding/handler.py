import boto3
import json
import logging

logger = logging.getLogger()
logger.setLevel(logging.INFO)

iam = boto3.client('iam')

def get_user_groups(username):
    """Get all groups a user belongs to."""
    response = iam.list_groups_for_user(UserName=username)
    return [g['GroupName'] for g in response['Groups']]

def delete_user_access_keys(username):
    """Delete all access keys for a user."""
    response = iam.list_access_keys(UserName=username)
    for key in response['AccessKeyMetadata']:
        iam.delete_access_key(
            UserName=username,
            AccessKeyId=key['AccessKeyId']
        )
        logger.info(f"Deleted access key {key['AccessKeyId']} for {username}")

def delete_user_mfa_devices(username):
    """Deactivate and delete all MFA devices."""
    response = iam.list_mfa_devices(UserName=username)
    for device in response['MFADevices']:
        iam.deactivate_mfa_device(
            UserName=username,
            SerialNumber=device['SerialNumber']
        )
        iam.delete_virtual_mfa_device(
            SerialNumber=device['SerialNumber']
        )
        logger.info(f"Removed MFA device for {username}")

def lambda_handler(event, context):
    """
    Triggered by backend when IT Ops offboards an employee.
    Revokes ALL AWS access — groups, keys, MFA, console login.

    Expected event payload:
    {
        "employee_id": "uuid",
        "email": "jane@innovatech.local"
    }

    Returns:
    {
        "success": true,
        "iam_username": "jane@innovatech.local",
        "actions_taken": ["removed from groups", "deleted access keys", ...],
        "message": "Employee fully offboarded from AWS"
    }
    """
    logger.info(f"Offboarding event received: {json.dumps(event)}")

    email       = event.get('email')
    employee_id = event.get('employee_id')

    if not email:
        return {
            'success': False,
            'error':   'email is required'
        }

    iam_username  = email
    actions_taken = []

    try:
        # ── Step 1: Remove from all IAM groups ────────────────────────────────
        groups = get_user_groups(iam_username)
        for group in groups:
            iam.remove_user_from_group(
                GroupName=group,
                UserName=iam_username
            )
            logger.info(f"Removed {iam_username} from group: {group}")
        actions_taken.append(f"removed from groups: {', '.join(groups) or 'none'}")

        # ── Step 2: Delete inline policies ───────────────────────────────────
        inline_policies = iam.list_user_policies(UserName=iam_username).get('PolicyNames', [])
        for policy_name in inline_policies:
            iam.delete_user_policy(UserName=iam_username, PolicyName=policy_name)
            logger.info(f"Deleted inline policy {policy_name} from {iam_username}")
        if inline_policies:
            actions_taken.append(f"deleted inline policies: {', '.join(inline_policies)}")

        # ── Step 3: Delete all access keys ────────────────────────────────────
        delete_user_access_keys(iam_username)
        actions_taken.append("deleted all access keys")

        # ── Step 3: Remove MFA devices ────────────────────────────────────────
        delete_user_mfa_devices(iam_username)
        actions_taken.append("removed MFA devices")

        # ── Step 4: Delete console login profile ──────────────────────────────
        try:
            iam.delete_login_profile(UserName=iam_username)
            actions_taken.append("deleted console login")
            logger.info(f"Deleted login profile for {iam_username}")
        except iam.exceptions.NoSuchEntityException:
            pass  # user had no console access, that's fine

        # ── Step 5: Delete the IAM user ───────────────────────────────────────
        iam.delete_user(UserName=iam_username)
        actions_taken.append("deleted IAM user")
        logger.info(f"Deleted IAM user: {iam_username}")

        return {
            'success':      True,
            'iam_username': iam_username,
            'actions_taken': actions_taken,
            'message':      f'Employee {iam_username} fully offboarded from AWS'
        }

    except iam.exceptions.NoSuchEntityException:
        logger.warning(f"IAM user not found: {iam_username}")
        # Not necessarily an error — user may never have had IAM access
        return {
            'success': True,
            'iam_username': iam_username,
            'actions_taken': ['IAM user did not exist — nothing to revoke'],
            'message': 'No IAM user found — portal record will still be offboarded'
        }

    except Exception as e:
        logger.error(f"Failed to offboard {iam_username}: {str(e)}")
        return {
            'success': False,
            'error':   str(e)
        }
