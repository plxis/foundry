#!/usr/bin/env python
"""
 Assigns a role on the provided G-Suite users' accounts, where the role is an AWS role ARN + IdP ARN.

 Pre-requisites for OSX:
  - brew install python
  - sudo easy_install pip
  - sudo -H pip install --upgrade google-api-python-client
  - export PYTHONPATH=/Library/Python/2.7/site-packages
"""
import argparse, json, boto3


def create_directory_service(adminEmail, secretJsonFile):
    from googleapiclient.discovery import build
    from oauth2client.service_account import ServiceAccountCredentials
    credentials = ServiceAccountCredentials.from_json_keyfile_name(
      secretJsonFile, scopes=['https://www.googleapis.com/auth/admin.directory.user'])
    credentials = credentials.create_delegated(adminEmail)
    return build('admin', 'directory_v1', credentials=credentials)

def patchUserCb(request_id, response, exception):
  if exception is not None:
    print('Error with batch request; request={0}; exception={1}'.format(request_id, exception))
    pass
  else:
    print('Batch request success; user={0}'.format(request_id))
    pass

def makeRole(role, providerArn, prefix, suffix):
  return {"arn": prefix + role + suffix, "providerArn": providerArn}

def getExistingRoles(existingUser):
  existingRoles = []
  customSchemas = existingUser.get('customSchemas')
  if customSchemas != None:
    awsSso = customSchemas.get('AWS-SSO')
    if awsSso != None:
      roles = awsSso.get('role')
      for role in roles:
        parts = role['value'].split(',')
        existingRoles.append(makeRole(parts[0],parts[1],'',''))
  return existingRoles

def removeProviderRoles(existingRoles, providerArn):
  roles = []
  for role in existingRoles:
    if role['providerArn'] != providerArn:
      roles.append(role)
  return roles

def appendGroupRoles(roles, userId, userGroups, groupRoles, providerArn):
  groupStr = userGroups.get(userId)
  if groupStr != None:
      groups = groupStr.split(",")
      for group in groups:
          tmpRole = groupRoles.get(group)
          if tmpRole:
              roles.append(makeRole(tmpRole, providerArn, '', ''))
          elif tmpRole is not None:
              print "ERROR: Cannot assign user "+userId+" to IAM role for unknown group "+group

def roleData(roles, user):
  roleList = []
  for role in roles:
    roleType = role['arn'].split('/')[-1]
    roleList.append({"value":role['arn'] + ',' + role['providerArn'],"customType": roleType})
  return {"customSchemas":{"AWS-SSO":{"role":roleList}}}


# Finds the ARNs for the Admin and Viewer roles, returning a map from group name to role ARN
def get_group_roles(role_prefix):
    group_roles = {}
    for group in [('Viewers', 'viewer'), ('Admins', 'admin')]:
        role_name = role_prefix+group[1]
        role_info = get_role(role_name)
        if role_info:
            group_roles[group[0]] = role_info['Arn']
    return group_roles


def get_role(role_name):
    client = boto3.client('iam')
    resp = client.get_role(RoleName=role_name)
    if resp:
        return resp['Role']
    else:
        print "ERROR: Unable to locate IAM role "+role_name
        return None



def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('delegateAdminEmail', help='admin email address in G-Suite that will be used for role assumption to submit the Admin API requests')
    parser.add_argument('secretJsonFile', help='JSON formatted file with G-Suite service account key and secret')
    parser.add_argument('providerArn', help='SAML SSO provider ARN')
    parser.add_argument('userGroupsFile', help='JSON file containing map of user ID keys to comma-seperated string of groups')
    parser.add_argument('rolePrefix', help='Prefix to append to the user roles')
    parser.add_argument('roleSuffix', help='Suffix to append to the user roles')
    args = parser.parse_args()

    aws_account_id = args.providerArn.split(":")[4]

    adminEmail = args.delegateAdminEmail
    if not adminEmail or adminEmail.upper() == "NONE" or adminEmail.upper() == "GSUITE_ADMIN_EMAIL":
        print "GSuite user linking disabled"
        return

    # Load user groups map
    with open(args.userGroupsFile, "r") as userGroupsJson:
      userGroups = json.load(userGroupsJson)
    if not userGroups:
        return

    # Look up Viewer/Admin group role ARNs
    groupRoles = get_group_roles(args.rolePrefix)

    service = create_directory_service(adminEmail=args.delegateAdminEmail, secretJsonFile=args.secretJsonFile)

    # Lookup existing users.
    existingUsers = {}
    response = service.users().list(customer='my_customer', projection='full', maxResults=500, orderBy='email').execute()
    for user in response['users']:
      existingUsers[user['primaryEmail']] = user

    # Link all users to their custom role in a single batch request to Google
    batch = service.new_batch_http_request(callback=patchUserCb)
    for userId in userGroups.keys():
      # Get all roles across all providers.
      existingUser = existingUsers.get(userId)
      if existingUser != None:
        roles = getExistingRoles(existingUser)

        # Clear out existing roles for this provider
        roles = removeProviderRoles(roles, args.providerArn)

        # Add the standard role for this provider, which allows users to modify their own IAM keys
        role_prefix = "arn:aws:iam::" + aws_account_id + ":role/" + args.rolePrefix
        roles.append(makeRole(userId, args.providerArn, role_prefix, args.roleSuffix))

        # Add role within this provider for each group the user belongs to.
        appendGroupRoles(roles, userId, userGroups, groupRoles, args.providerArn)

        # Submit this directory API request into the batch request.
        batch.add(service.users().patch(userKey=userId,
          body=roleData(roles=roles, user=userId)),
          None, userId)
      else:
        print('WARNING: User does not exist in G-Suite; user=' + userId)

    # Execute the full batch of user role updates to G-Suite.
    batch.execute()

if __name__ == '__main__':
    main()