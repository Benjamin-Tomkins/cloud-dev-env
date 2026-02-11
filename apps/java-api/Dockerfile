FROM maven:3.9-eclipse-temurin-25 AS build
WORKDIR /app
COPY pom.xml .
RUN mvn dependency:go-offline -B
COPY src ./src
RUN mvn package -Dmaven.test.skip=true -B

FROM eclipse-temurin:25-jre
WORKDIR /app
COPY --from=build /app/target/*.jar app.jar
RUN useradd -m appuser || true
USER appuser
EXPOSE 8080
ENTRYPOINT ["java", "--sun-misc-unsafe-memory-access=allow", "-jar", "app.jar"]
