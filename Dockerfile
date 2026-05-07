FROM rockylinux:9
LABEL authors="darko.lesendric@activecollab.com"

# Remi repo daje PHP 7.4 i PHP 8.3 paralelno kao SCL pakete.
# Sistemski php modul se resetuje da ne blokira Remi verzije.
RUN dnf install -y epel-release && \
    dnf install -y https://rpms.remirepo.net/enterprise/remi-release-9.rpm && \
    dnf module reset php -y && \
    dnf install -y supervisor ImageMagick mariadb unzip && \
    dnf clean all

# PHP 7.4 (SCL) — koristi se za stepenice 5.8.7→6.0.7
# Binarija: /opt/remi/php74/root/usr/bin/php  (symlink: /usr/bin/php74)
# FPM:      /opt/remi/php74/root/usr/sbin/php-fpm  na portu 9004
RUN dnf install -y \
    php74 \
    php74-php-fpm \
    php74-php-mysqlnd \
    php74-php-mbstring \
    php74-php-gd \
    php74-php-curl \
    php74-php-zip \
    php74-php-xml \
    php74-php-intl \
    php74-php-bcmath \
    php74-php-pecl-imagick \
    php74-php-exif \
    php74-php-opcache && \
    dnf clean all

# PHP 8.1 (SCL) — koristi se za stepenice 6.0.7→7.4.766
# Binarija: /opt/remi/php81/root/usr/bin/php  (symlink: /usr/bin/php81)
# FPM:      /opt/remi/php81/root/usr/sbin/php-fpm  na portu 9007
RUN dnf install -y \
    php81 \
    php81-php-fpm \
    php81-php-mysqlnd \
    php81-php-mbstring \
    php81-php-gd \
    php81-php-curl \
    php81-php-zip \
    php81-php-xml \
    php81-php-intl \
    php81-php-bcmath \
    php81-php-pecl-imagick \
    php81-php-exif \
    php81-php-opcache && \
    dnf clean all

# PHP 8.1 FPM pool: TCP port 9007, worker user nobody, allow all IPs
RUN sed -i \
    -e 's|^listen = .*|listen = 0.0.0.0:9007|' \
    -e 's|^user = .*|user = nobody|' \
    -e 's|^group = .*|group = nobody|' \
    -e 's|^listen.allowed_clients|;listen.allowed_clients|' \
    /etc/opt/remi/php81/php-fpm.d/www.conf

# PHP 8.3 (SCL) — koristi se za stepenice 7.4.766 i novije
# Binarija: /opt/remi/php83/root/usr/bin/php  (symlink: /usr/bin/php83)
# FPM:      /opt/remi/php83/root/usr/sbin/php-fpm  na portu 9008
RUN dnf install -y \
    php83 \
    php83-php-fpm \
    php83-php-mysqlnd \
    php83-php-mbstring \
    php83-php-gd \
    php83-php-curl \
    php83-php-zip \
    php83-php-xml \
    php83-php-intl \
    php83-php-bcmath \
    php83-php-pecl-imagick \
    php83-php-exif \
    php83-php-opcache && \
    dnf clean all

# PHP 7.4 FPM pool: TCP port 9004, worker user nobody, allow all IPs
RUN sed -i \
    -e 's|^listen = .*|listen = 0.0.0.0:9004|' \
    -e 's|^user = .*|user = nobody|' \
    -e 's|^group = .*|group = nobody|' \
    -e 's|^listen.allowed_clients|;listen.allowed_clients|' \
    /etc/opt/remi/php74/php-fpm.d/www.conf

# PHP 8.3 FPM pool: TCP port 9008, worker user nobody, allow all IPs
RUN sed -i \
    -e 's|^listen = .*|listen = 0.0.0.0:9008|' \
    -e 's|^user = .*|user = nobody|' \
    -e 's|^group = .*|group = nobody|' \
    -e 's|^listen.allowed_clients|;listen.allowed_clients|' \
    /etc/opt/remi/php83/php-fpm.d/www.conf

# Symlinks za direktan poziv iz migrate.sh
RUN ln -sf /opt/remi/php74/root/usr/bin/php /usr/bin/php74 && \
    ln -sf /opt/remi/php81/root/usr/bin/php /usr/bin/php81 && \
    ln -sf /opt/remi/php83/root/usr/bin/php /usr/bin/php83

RUN echo "memory_limit = 512M" >> /etc/opt/remi/php74/php.d/99-migrate.ini && \
    echo "memory_limit = 512M" >> /etc/opt/remi/php81/php.d/99-migrate.ini && \
    echo "memory_limit = 512M" >> /etc/opt/remi/php83/php.d/99-migrate.ini

COPY supervisord.conf /etc/supervisord.conf

RUN mkdir -p /var/www/html/app

WORKDIR /var/www/html/app

EXPOSE 9004 9008

CMD ["/usr/bin/supervisord", "-n", "-c", "/etc/supervisord.conf"]
