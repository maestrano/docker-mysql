FROM mysql:5.7

VOLUME ["/var/lib/mysql","/snapshots"]

# Point-in-time backup script with backup rotation
COPY backup.sh /usr/local/bin/

COPY docker-entrypoint.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/*
ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]

EXPOSE 3306
CMD ["mysqld"]
