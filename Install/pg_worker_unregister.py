import re
import sys

worker_name = sys.argv[1]
path = sys.argv[2]

flag = False
with open(path,'r') as f:
    regex = re.compile(r"^#?(shared_preload_libraries)\s*=\s*'(.*)'")
    new_file = ''
    for l in f:
        result = regex.match(l)
        if result:
            flag = True
            print(l.rstrip('\n'))
            w_str = result.group(2).replace(' ','')
            param = result.group(1)
            if w_str:
                workers = set(w_str.split(','))
                if worker_name not in workers:
                    print('\033[1;91mERROR:\033[0m worker %s not registered, aborting ...\n' % (worker_name))
                    exit(1)
                workers.remove(worker_name)
                new_line = param+' = \''+','.join(w for w in workers)+'\'\n'
                new_file += new_line
                print(new_line)
            else:
                 print('\033[1;91mERROR:\033[0m worker %s not registered, aborting ...\n' % (worker_name))
                 exit(1)
        else:
            new_file += l
    if not flag:
        print('ERROR: pattern "shared_preload_libraries" not found, aborting')
        exit(1)
with open(path,'w') as f:
    f.write(new_file)


