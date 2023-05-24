#!/bin/bash
# Ubuntu 20.04, NGINX 1.18 ver 기준
# 원본 : https://github.com/wmnnd/nginx-certbot



# docker-compose 설치 확인
if ! [ -x "$(command -v docker-compose)" ]; then 		# -x $(명령어) : 명령어를 실행 가능하면 참, 그렇지 않으면 거짓 / command -v : 경로 반환

  echo 'Error: docker-compose is not installed.' >&2 		# >&2 : 모든 출력을 강제로 표준 에러로 출력
								# > : 프로그램의 출력을 표준 출력에서 지정한 출력으로 변경
								# & : 표준 입출력 숫자를 인식하게 해주는 설정값. 이게 없을 경우 뒤의 표준 입출력 값을 파일로 인식
								# 2 : 표준 에러
  exit 1
fi


# 참고 : 기존에 생성한 네트워크가 존재하는 상태에서 deploy.sh와 docker-compose.yml 경로를 바꿔 실행하면 Pool overlaps with other one on this address space 에러 발생

# 변수 설정
domains=$SERVER_NAME
rsa_key_size=$RSA_KEY_SIZE
data_path="/etc/letsencrypt"
email="cmg4739@gmail.com" 					# Adding a valid address is strongly recommended
staging=1							# 스테이징 환경 : 운영 환경과 거의 동일한 환경을 만들어놓고 운영 환경으로 이전하기 전 검증하는 환경






# 이미 ssl 인증서가 존재할 경우 다시 발급받을 것인지 확인
if [ -d "$data_path" ]; then # -d file : file이 디렉터리이면 참
								# read -p "command" val: command를 띄운 후 사용자 입력을 받아 val에 저장 
  read -p "Existing data found for $domains. Continue and replace existing certificate? (y/N) " decision
  if [ "$decision" != "Y" ] && [ "$decision" != "y" ]; then
    exit
  fi
fi



# options-ssl-nginx.conf, ssl-dhparams.pem 없을 경우 설치

# options-ssl-nginx.conf : SSL 관련 설정 존재(ssl_session_cache, ssl_session_timeout, ssl_protocols, ssl_prefer_server_ciphers, ssl_ciphers
# ssl_ciphers : 보안 통신 과정에서 사용할 암호화 알고리즘 지정

# ssl-dhparams.pem : Diffie-Hellman 키 교환 방식 설정 (좀 더 구체적으로 알아보기)

# DNS 방식에서는 필요 없었음, 하지만 webroot 방식에서는 필요
if [ ! -e "$data_path/options-ssl-nginx.conf" ] || [ ! -e "$data_path/ssl-dhparams.pem" ]; then	# -e file : file이 존재하면 참
  echo "### Downloading recommended TLS parameters ..."
  mkdir -p "$data_path"						# mkdir -p : 존재하지 않는 중간의 디렉토리 자동 생성
# curl -s : 에러가 발생해도 출력하지 않음
  curl -s https://raw.githubusercontent.com/certbot/certbot/master/certbot-nginx/certbot_nginx/_internal/tls_configs/options-ssl-nginx.conf > "$data_path/options-ssl-nginx.conf"
  curl -s https://raw.githubusercontent.com/certbot/certbot/master/certbot/certbot/ssl-dhparams.pem > "$data_path/ssl-dhparams.pem"
  echo
fi





# Certbot 실행시켜 발급받은 키 가져오기
# 주의 : \로 연결한 커맨드 사이에 주석이 존재할 경우 에러 발생
echo "### Creating dummy certificate for $domains ..."
path="/etc/letsencrypt/live/$domains"
mkdir -p "$data_path/live/$domains"
docker-compose run --rm --entrypoint "\
  openssl req -x509 -nodes -newkey rsa:$rsa_key_size -days 1\
    -keyout '$path/privkey.pem' \
    -out '$path/fullchain.pem' \
    -subj '/CN=localhost'" certbot
echo


# Dockerfile의 ENTRYPOINT보다 docker-compose.yml의 entrypoint가 우선 순위가 더 높음
# openssl : SSL, TLS 관련 기능들을 제공하는 오픈 소스 라이브러리
# req : 인증서 서명 요청서 생성하고 처리
# X.509 : 공개 키 기반(PKI)의 ITU-T 표준
# -nodes : 개인 키가 생성될 때 암호화되지 않음
# -newkey arg : 새로운 인증 요청서와 개인 키 생성 / arg : 요청서와 개인 키의 타입
# -days n : -x509 옵션 사용 시 인증 가능 기간 설정
# -keyout filename : 생성된 개인 키를 filename 경로로 생성
# -out filename : 생성된 파일을 filename 경로로 생성
# -subj arg : 입력 요청의 Subject를 지정된 데이터로 대체하고 수정된 요청을 출력
# Subject : 인증서 필수 항목으로 소유자의 정보를 나타냄
# CN : Common Name, SSL 인증서로 보호되는 서버 이름


# api 서버 실행
echo "### Starting toda ..."
docker-compose up --force-recreate -d api utils redis		# --force-recreate : 모든 컨테이너를 중지하고 다시 생성
echo







# Certbot 컨테이너의 발급한 키 전부 삭제
echo "### Deleting dummy certificate for $domains ..."
docker-compose run --rm --entrypoint "\
  rm -Rf /etc/letsencrypt/live/$domains && \			# rm -Rf : 최상위 디렉토리 밑에 있는 모든 파일과 디렉토리를 삭제하고 자기 자신까지 삭제
  rm -Rf /etc/letsencrypt/archive/$domains && \
  rm -Rf /etc/letsencrypt/renewal/$domains.conf" certbot
echo








# 인증 진행할 도메인이 여러 개일 경우 전부 인증하는 옵션 설정
# -d domain : domain 주소 인증 시 필요 옵션
echo "### Requesting Let's Encrypt certificate for $domains ..."
domain_args=""
for domain in "${domains[@]}"; do				# ${} : parameter substitution, 감싼 부분에 변수 대입
								# array[@] : array 배열의 모든 원소를 가져옴
  domain_args="$domain_args -d $domain"
done










# 유효한 이메일인지 체크
# Select appropriate email arg
case "$email" in
  "") email_arg="--register-unsafely-without-email" ;;		# {String}) : String 조건일 경우 실행
  *) email_arg="--email $email" ;;				# *) : default, 위의 조건 제외 나머지
esac










# 스테이징 옵션 설정
# Enable staging mode if needed
if [ $staging != "0" ]; then staging_arg="--staging"; fi











# Certbot Webroot 방식으로 인증서 생성
docker-compose run --rm --entrypoint "\
  certbot certonly --webroot --webroot-path=/var/www/certbot \
    $staging_arg \
    $email_arg \
    $domain_args \
    --rsa-key-size $rsa_key_size \
    --agree-tos \
    --no-eff-email \
    --force-renewal" certbot
echo










# 웹 서버 재부팅
echo "### Reloading toda:php ..."
docker-compose exec api service nginx restart
