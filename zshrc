# Path to your Oh My Zsh installation.
export ZSH="$HOME/.oh-my-zsh"

ZSH_THEME="robbyrussell"

plugins=(git zoxide gradle)

source $ZSH/oh-my-zsh.sh

alias cd="z"
alias gr="gradle"

