deploy() {
    if [ "$1" = "next" ]; then
        scp "next/.env.local.$2" "$3:/home/web/next/.env.local"
        scp "docker-compose.$2.yml" "$3:/home/web/docker-compose.yml"
        ssh -t "$3" "cd /home/web/next && git pull && docker compose up -d --no-deps --build next"
    elif [ "$1" = "directus" ]; then
        scp "directus/.env" "$3:/home/web/directus/.env"
        scp "docker-compose.$2.yml" "$3:/home/web/docker-compose.yml"
        ssh -t "$3" "docker compose up -d --no-deps --build directus"
    elif [ "$1" = "nginx" ]; then
        scp "nginx/nginx-certbot.env" "$3:/home/web/nginx/nginx-certbot.env"
        scp "nginx/.htpasswd" "$3:/home/web/nginx/.htpasswd"
        scp "nginx/$2.conf" "$3:/home/web/nginx/user_conf.d/nginx.conf"
        ssh -t "$3" "docker compose up -d --no-deps --build nginx"
    fi
}

logs() {
    ssh -t "$1" "docker compose logs --follow"
}

database_backup_local() {
    docker compose exec database pg_dump -v --clean -U directus -Fc directus > data/backups/local-$(date "+%F")"-"$(date "+%s").dump

    if [ $? -eq 0 ]; then
        echo "Local backup succeeded."
        return 0 
    else
        echo "Local backup failed."
        return 1
    fi
}

database_backup_remote() {
    # Run pg_dump command remotely to create a database backup
    ssh -t "$1" "docker compose exec database pg_dump -v --clean -U directus -Fc directus > /tmp/database-backup.dump"

    # Check if pg_dump command was successful
    if [ $? -eq 0 ]; then
        remote_backup_path="data/backups/$1-$(date "+%F")"-"$(date "+%s").dump"
        # If successful, copy the backup file to local machine
        scp "$1:/tmp/database-backup.dump" "$remote_backup_path"
        # Check if scp command was successful
        if [ $? -eq 0 ]; then
            # Delete the temporary backup file on the remote server
            ssh -t "$1" "rm /tmp/database-backup.dump"
            echo "Remote backup from: $1 to: $remote_backup_path completed successfully."
            return 0 
        else
            echo "Failed to copy backup file. Please check SSH and SCP permissions."
            return 1
        fi
    else
        echo "Remote backup failed."
        return 1
    fi
}

database_restore_local() {
    docker compose exec -T database pg_restore -vc -U directus -d directus < "$1"
}

database_pull_remote() {
    database_backup_remote $1
    if [ $? -eq 0 ]; then
        database_backup_local
        if [ $? -eq 0 ]; then
            database_restore_local "$remote_backup_path"
            if [ $? -eq 0 ]; then
                echo "Database restore from: $1 to: local completed successfully."
            else
                echo "Database restore from remote failed."
            fi
        else
            echo "Database restore from remote failed."
        fi
    else
        echo "Backup failed."
    fi
}

pull_uploads() {
    rsync -avz --exclude=".DS_Store" --stats $2 "$1:/home/web/directus/uploads/" ./directus/uploads/
}

push_uploads() {
    rsync -avz --exclude=".DS_Store" --stats $2 ./directus/uploads/ "$1:/home/web/directus/uploads/"
}

push_extensions() {
    rsync -avz --stats --include-from=<(echo "+ extensions/
+ extensions/*/
+ extensions/*/package.json
+ extensions/*/dist/
+ extensions/*/dist/*.js
- .DS_Store
- *") $2 ./directus/ "$1:/home/web/directus/"
}

schema_snapshot_remote() {
    ssh -t "$1" "docker compose exec directus npx directus schema snapshot --yes ./snapshots/tmp-snapshot.yaml"

    if [ $? -eq 0 ]; then
        local_snapshot_path="directus/snapshots/$1-$(date "+%F")"-"$(date "+%s").yaml"
        # If successful, copy the snapshot file to local machine
        scp "$1:/home/web/directus/snapshots/tmp-snapshot.yaml" "$local_snapshot_path"
        # Check if scp command was successful
        if [ $? -eq 0 ]; then
            # Delete the temporary snapshot file on the remote server
            ssh -t "$1" "rm /home/web/directus/snapshots/tmp-snapshot.yaml"
            echo "Remote snapshot from: $1 to: $local_snapshot_path completed successfully."
            return 0
        else
            echo "Failed to copy snapshot file. Please check SSH and SCP permissions."
            return 1
        fi
    else
        echo "Remote snapshot failed."
        return 1
    fi
}