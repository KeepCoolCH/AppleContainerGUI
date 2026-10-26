#include <arpa/inet.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <pthread.h>
#include <semaphore.h>

struct query { int listener; struct sockaddr_in client; socklen_t client_len; unsigned char bytes[65536]; ssize_t size; };
static struct sockaddr_in upstream;
static sem_t slots;

static void *forward(void *value) {
    struct query *q = value;
    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    struct timeval timeout = { 3, 0 };
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    if (fd >= 0 && connect(fd, (struct sockaddr *)&upstream, sizeof(upstream)) == 0) {
        unsigned char packet[65536];
        memcpy(packet, "ACG8", 4);
        memcpy(packet + 4, &q->client.sin_addr, 4);
        memcpy(packet + 8, q->bytes, q->size);
        if (send(fd, packet, q->size + 8, 0) > 0) {
            ssize_t count = recv(fd, packet, sizeof(packet), 0);
            if (count >= 12 && packet[0] == q->bytes[0] && packet[1] == q->bytes[1])
                sendto(q->listener, packet, count, 0, (struct sockaddr *)&q->client, q->client_len);
        }
    }
    if (fd >= 0) close(fd);
    free(q);
    sem_post(&slots);
    return NULL;
}

int main(void) {
    char *setting = getenv("DNS_UPSTREAM");
    if (!setting) return 1;
    char address[64];
    snprintf(address, sizeof(address), "%s", setting);
    char *colon = strrchr(address, ':');
    if (!colon) return 1;
    *colon++ = 0;
    upstream.sin_family = AF_INET;
    upstream.sin_port = htons(atoi(colon));
    if (inet_pton(AF_INET, address, &upstream.sin_addr) != 1) return 1;
    int listener = socket(AF_INET, SOCK_DGRAM, 0);
    struct sockaddr_in local = { .sin_family = AF_INET, .sin_port = htons(53), .sin_addr.s_addr = INADDR_ANY };
    if (listener < 0 || bind(listener, (struct sockaddr *)&local, sizeof(local))) return 1;
    sem_init(&slots, 0, 64);
    for (;;) {
        struct query *q = calloc(1, sizeof(*q));
        if (!q) return 1;
        q->listener = listener;
        q->client_len = sizeof(q->client);
        q->size = recvfrom(listener, q->bytes, sizeof(q->bytes) - 8, 0, (struct sockaddr *)&q->client, &q->client_len);
        if (q->size < 12 || sem_trywait(&slots)) { free(q); continue; }
        pthread_t thread;
        if (pthread_create(&thread, NULL, forward, q)) { sem_post(&slots); free(q); continue; }
        pthread_detach(thread);
    }
}
