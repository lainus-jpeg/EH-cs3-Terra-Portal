import boto3
import json
import secrets
import string
import logging

logger = logging.getLogger()
logger.setLevel(logging.INFO)

iam = boto3.client('iam')

ROLE_TO_GROUP = {
    'it_ops':    'cs3-dev-it-ops',
    'security':  'cs3-dev-security',
    'platform':  'cs3-dev-platform',
    'manager':   'cs3-dev-management',
    'developer': 'cs3-dev-employees',
    'sales_rep': 'cs3-dev-employees',
    'employee':  'cs3-dev-employees',
}

def generate_temp_password():
    alphabet = string.ascii_letters + string.digits + '!@#$%^&*()'
    while True:
        password = ''.join(secrets.choice(alphabet) for _ in range(16))
        if (any(c.isupper() for c in password) and
            any(c.islower() for c in password) and
            any(c.isdigit() for c in password) and
            any(c in '!@#$%^&*()' for c in password)):
            return password

def lambda_handler(event, context):
    logger.info(f"Onboarding event received: {json.dumps(event)}")
    employee_id = event.get('employee_id')
    name        = event.get('name')
    email       = event.get('email')
    role        = event.get('role', 'employee')
    department  = event.get('department', '')

    if not email or not name:
        return {'success': False, 'error': 'email and name are required'}

    iam_username  = email
    group_name    = ROLE_TO_GROUP.get(role, 'cs3-dev-employees')
    temp_password = generate_temp_password()

    try:
        iam.create_user(
            UserName=iam_username,
            Tags=[
                {'Key': 'EmployeeId', 'Value': employee_id or ''},
                {'Key': 'Department', 'Value': department},
                {'Key': 'Role',       'Value': role},
                {'Key': 'ManagedBy',  'Value': 'cs3-portal'},
            ]
        )
        logger.info(f"Created IAM user: {iam_username}")

        iam.create_login_profile(
            UserName=iam_username,
            Password=temp_password,
            PasswordResetRequired=True
        )
        logger.info(f"Created login profile for: {iam_username}")

        iam.put_user_policy(
            UserName=iam_username,
            PolicyName='AllowSelfPasswordChange',
            PolicyDocument=json.dumps({
                "Version": "2012-10-17",
                "Statement": [{"Effect": "Allow", "Action": ["iam:ChangePassword", "iam:GetAccountPasswordPolicy"], "Resource": "*"}]
            })
        )
        logger.info(f"Attached self-password-change policy to: {iam_username}")

        iam.add_user_to_group(GroupName=group_name, UserName=iam_username)
        logger.info(f"Added {iam_username} to group: {group_name}")

        return {
            'success':       True,
            'iam_username':  iam_username,
            'temp_password': temp_password,
            'group':         group_name,
            'message':       f'IAM user created and added to {group_name}'
        }

    except iam.exceptions.EntityAlreadyExistsException:
        logger.warning(f"IAM user already exists: {iam_username}")
        return {'success': False, 'error': f'IAM user {iam_username} already exists'}

    except Exception as e:
        logger.error(f"Failed to onboard {iam_username}: {str(e)}")
        return {'success': False, 'error': str(e)}
