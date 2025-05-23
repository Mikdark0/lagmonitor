#!/bin/bash

# Create or clear the whole.txt file
> whole.txt

# Loop through each file in the current directory
for file in *; do
    # Skip directories, whole.txt, and this script itself
    if [ -d "$file" ] || [ "$file" == "whole.txt" ] || [ "$file" == "concat_files.sh" ]; then
        continue
    fi
    
    # Write the filename
    echo "=== $file ===" >> whole.txt
    # Write the file content
    cat "$file" >> whole.txt
    # Add two blank lines between files
    echo -e "\n" >> whole.txt
done

echo "All files have been concatenated into whole.txt"
