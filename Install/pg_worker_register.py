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
            #print(l.rstrip('\n'))
            w_str = result.group(2).replace(' ','')
            param = result.group(1)
            if w_str:
                workers = set(w_str.split(','))
                if worker_name in workers:
                    print('\033[1;93mWARNING:\033[0m worker %s already registered.\n' % (worker_name))
                    exit(0)
                new_line = param+' = \''+','.join(w for w in workers)+','+worker_name+'\'\n'
                new_file += new_line
                print(new_line)
            else:
                new_line = param+' = \''+worker_name+'\'\n'
                new_file += new_line
                print(new_line)
        else:
            new_file += l
    if not flag:
        print('ERROR: pattern "shared_preload_libraries" not found, aborting')
        exit(1)
with open(path,'w') as f:
    f.write(new_file)


