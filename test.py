import sys
import relay_ops

def main():
    if len(sys.argv) != 2:
        print("Usage: test.py <module_number>")
        sys.exit(1)

    module_number = sys.argv[1]

    if module_number == '1':
        relay_ops.test_all()  # Assuming this tests Module 1
    elif module_number == '2':
        relay_ops.test_module_2()
    else:
        print("Invalid module number. Please choose 1 or 2.")
        sys.exit(1)

if __name__ == '__main__':
    main()
