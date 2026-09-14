FROM golang:1.25 AS builder
WORKDIR /plugin
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -o /plugin/plugin .

FROM alpine:3.21
WORKDIR /
RUN mkdir -p /plugin
COPY --from=builder /plugin/plugin /plugin/plugin
