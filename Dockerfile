FROM rockylinux:latest
LABEL authors="darko.lesendric@activecollab.com"

ENTRYPOINT ["top", "-b"]
