-- Restrict radius user to only the privileges FreeRADIUS needs
REVOKE ALL PRIVILEGES ON radius.* FROM 'radius'@'%';
GRANT SELECT, INSERT, UPDATE, DELETE ON radius.* TO 'radius'@'%';
FLUSH PRIVILEGES;
