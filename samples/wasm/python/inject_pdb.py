import ast
import os
import re
import sys
import textwrap

def get_debug_operator_path(operator_path):
    debug_file_suffix = "_debug"
    directory_path = os.path.dirname(operator_path)
    filename, ext = os.path.splitext(os.path.basename(operator_path))
    dbg_operator_path = os.path.join(directory_path, f"{filename}{debug_file_suffix}{ext}")
    return dbg_operator_path

def get_syntax_bdbquit_catchphrase(indent):
    syntax_catch = "except Exception as e:"
    syntax_check_str = 'if str(type(e).__name__) == "BdbQuit":'
    syntax_return = "pass"
    syntax_else = "else:"
    syntax_raise = "raise e\n"
    return "\n".join([
        syntax_catch,
        textwrap.indent(syntax_check_str, indent),
        textwrap.indent(textwrap.indent(syntax_return, indent), indent),
        textwrap.indent(syntax_else, indent),
        textwrap.indent(textwrap.indent(syntax_raise, indent), indent)
    ])

def generate_imports(tree, code, dbg_file):
    for node in ast.walk(tree):
        if isinstance(node, ast.ImportFrom):
            syntax_import = ast.get_source_segment(code, node)
            dbg_file.write(syntax_import + "\n")
        if isinstance(node, ast.Import):
            syntax_import = ast.get_source_segment(code, node)
            dbg_file.write(syntax_import + "\n")

def generate_fnx_body(tree, code, dbg_file):
    syntax_try = "try:"
    syntax_set_trace = "pdb.set_trace()"
    for node in ast.walk(tree):
        if isinstance(node, ast.ClassDef):
            syntax_class_body = ast.get_source_segment(code, node)
            split_body = syntax_class_body.splitlines(keepends=True)
            dbg_file.write(split_body[0])

        if isinstance(node, ast.FunctionDef):
            body = ast.get_source_segment(code, node)
            split_body = body.splitlines(keepends=True)
            fnx_header = split_body[0].rstrip('\n')
            fnx_content = ''.join(split_body[1:])

            # Use Regex to get the whitespace and use that as golden standard for the customer's indentation
            match = re.match(r'^(\s*)', fnx_content)
            indent = match.group(1) if match else '  '
            indent_len = max(2, len(indent) // 2 if len(indent) > 2 else len(indent))
            indent = ' ' * indent_len

            # Dedent to sterize the indentation
            fnx_content = textwrap.dedent(fnx_content)
            new_code = "\n".join(
                [
                    textwrap.indent(fnx_header, indent),
                    textwrap.indent(syntax_try, indent * 2),
                    textwrap.indent(syntax_set_trace, indent * 3),
                    textwrap.indent(fnx_content, indent *3),
                    textwrap.indent(get_syntax_bdbquit_catchphrase(indent), indent * 2)
                ]
            )
            dbg_file.write(new_code + "\n")

# Main
if __name__ == "__main__":
    #python C:\Users\yophilav\vscode-tinykube\extension\assets\templates\pythonOperator\inject_pdb.py "C:\\Users\\yophilav\\vscode-tinykube\\extension\\map.py"
    if len(sys.argv) < 2 or not sys.argv[1].endswith('.py') or not os.path.isfile(sys.argv[1]) or not os.access(sys.argv[1], os.R_OK):
        print("Error: Please provide a valid, readable Python (.py) file as an argument.")
        sys.exit(1)
    operator_path = sys.argv[1]
    file = open(operator_path, "r")
    code = file.read()
    tree = ast.parse(code)

    dbg_operator_path = get_debug_operator_path(operator_path)
    dbg_file = open(dbg_operator_path, "w")
    generate_imports(tree, code, dbg_file)
    dbg_file.write("import pdb\n\n")
    generate_fnx_body(tree, code, dbg_file)
    file.close()
    dbg_file.close()