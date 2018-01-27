import argparse,json,subprocess,collections,time,sys,os

def logit(str):
  # by default do not log to stdout or it will interfere with terraform
  #with open('/tfdata/provisionUsers.log', 'a') as fp:
  #  fp.write(str + '\n')
  return

def getNewUserList(file):
  users = []
  with open(file, "r") as usersJson:
    users = json.load(usersJson)
  return users

def getExistingUsers(contextPath):
  users = []
  completed = subprocess.check_output(["aws", "iam", "list-users", "--path-prefix", contextPath])
  usersJson = json.loads(completed)
  for user in usersJson["Users"]:
    users.append(user["UserName"])
  logit("Found existing users; count=" + str(len(users)))
  return users

def difference(list1, list2):
  c1 = collections.Counter(list1)
  c2 = collections.Counter(list2)
  result = (c1 - c2).keys()
  logit("c1=" + str(c1) + "; c2=" + str(c2) + "; result=" + str(result))
  return result

def deleteUsers(users):
  for user in users:
    logit("Deleting user; username=" + user)
    # Delete SSH public keys
    completed = subprocess.check_output(["aws", "iam", "list-ssh-public-keys", "--user-name", user])
    keys = json.loads(completed)
    for key in keys["SSHPublicKeys"]:
      logit("Deleting SSH public key; username=" + user + "; sshKeyId=" + key["SSHPublicKeyId"])
      completed = subprocess.check_output(["aws", "iam", "delete-ssh-public-key", "--user-name", user, "--ssh-public-key-id", key["SSHPublicKeyId"]])
    # Delete access keys
    completed = subprocess.check_output(["aws", "iam", "list-access-keys", "--user-name", user])
    keys = json.loads(completed)
    for key in keys["AccessKeyMetadata"]:
      logit("Deleting access key; username=" + user + "; accessKeyId=" + key["AccessKeyId"])
      completed = subprocess.check_output(["aws", "iam", "delete-access-key", "--user-name", user, "--access-key-id", key["AccessKeyId"]])
    completed = subprocess.check_output(["aws", "iam", "delete-user", "--user-name", user])

def addUsers(users, contextPath):
  for user in users:
    logit("Creating user; username=" + user + "; path=" + contextPath)
    completed = subprocess.check_output(["aws", "iam", "create-user", "--user-name", user, "--path", contextPath])


def transposeInputToOutput():
  stdin = None
  try:
    stdin = json.load(sys.stdin)
    json.dump(transpose(stdin), sys.stdout)
  except ValueError:
    None

def transpose(in_dict):
  tmp = in_dict
  tmp = strings_to_lists(tmp)
  tmp = invert(tmp)
  tmp = lists_to_strings(tmp)
  return tmp

def invert(in_dict):
  newdict = {}
  for k in in_dict:
      for v in in_dict[k]:
          newdict.setdefault(v, []).append(k)
  return newdict

def lists_to_strings(dict):
  newdict = {}
  for k,v in dict.items():
      newdict[k] = ",".join(v)
  return newdict

def strings_to_lists(dict):
  newdict = {}
  for k,v in dict.items():
      groups = v.split(",")
      trimmedGroups = []
      for group in groups:
          trimmedGroups.append(group.strip())
      newdict[k] = trimmedGroups
  return newdict

def main():
  parser = argparse.ArgumentParser()
  parser.add_argument('mode', help='add to add the missing users, or delete to delete the extra users')
  parser.add_argument('usersFile', help='JSON file containing list of user IDs')
  parser.add_argument('context', help='Unique context for this environment deployment; should be consistent across redeployments to the same context.')
  args = parser.parse_args()
  context = "/" + args.context + "/"
  mode = args.mode
  if os.path.isfile(args.usersFile):
    newList = getNewUserList(args.usersFile)
    oldList = getExistingUsers(context)
    if mode == "add":
      addUsers(difference(newList, oldList), context)
    elif mode == "delete":
      deleteUsers(difference(oldList, newList))
    else:
      logit("Invalid mode; allowed modes: add, delete")
      exit(1)
  transposeInputToOutput()
  exit(0)

if __name__ == '__main__':
  main()