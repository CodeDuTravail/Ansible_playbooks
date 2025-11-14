# Ansible_playbooks

A collection of playbooks for various purposes.

* bashrc_builder.yml
    ```bash
    ansible-playbook bashrc_builder.yml --tags "users" -i inventory.yml --ask-vault-pass -evars_file.yml
    ansible-playbook bashrc_builder_all.yml --tags "root-only" -i inventory.yml --ask-vault-pass -evars_file.yml
    ```
    >A playbook for a complete.bashrc generation
    - History options
    - Invites with different color patterns for non-root users and root.
    - Custom Aliases

* add_bashrc_aliases.yml
    >Obviously obvious.

* unattended_upgrades.yml
    >A playbook to set unattended upgrades on a fresh build debian server.

