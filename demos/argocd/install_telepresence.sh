#!/bin/bash

# Function to check if telepresence is installed
check_telepresence_installed() {
    if command -v telepresence &> /dev/null; then
        echo "Telepresence is already installed."
        return 0
    else
        echo "Telepresence is not installed."
        return 1
    fi
}

# Install telepresence if not installed
install_telepresence() {
    echo "Installing Telepresence..."
    if command -v brew &> /dev/null; then
        brew install telepresence
        if [ $? -eq 0 ]; then
            echo "Telepresence installed successfully."
        else
            echo "Failed to install Telepresence. Please check your Homebrew setup."
            exit 1
        fi
    else
        echo "Homebrew is not installed. Please install Homebrew and rerun the script."
        exit 1
    fi
}

# Main script logic
if ! check_telepresence_installed; then
    install_telepresence
fi
