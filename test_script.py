import sys
import relay_ops

def main():
    if len(sys.argv) != 2:
        print("Usage: test.py <module_number>")
        sys.exit(1)

    module_number = sys.argv[1]

    if module_number == 'ma':
        relay_ops.test_all()  
    elif module_number == 'm1':
        relay_ops.test_module_1()
    elif module_number == 'm2':
        relay_ops.test_module_2()
    else:
        print("Invalid module number. Please choose 1 or 2 or ma.")
        sys.exit(1)

if __name__ == '__main__':
    main()
