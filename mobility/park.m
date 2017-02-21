function [ x, y, t ] = park ( x0, y0, speed, direction, right, curb_distance )

% parameters: parallel parking speed (m/s) and distance (m)
parking_speed = 0.8;
brake_distance = 7.5;

% first step
x(1) = 0;
y(1) = 0;

% brake to a full stop
dir = 0;
t_brake = 2 * brake_distance / speed;
a = -speed / t_brake;
for (t = 1 : t_brake / 0.001),
    speed = speed + a * 0.001;
    [x(t + 1), y(t + 1)] = move(x(t), y(t), dir, speed, 0.001);
end

% back up to the curb
t_park = curb_distance * pi / (2 * parking_speed);
for (t = t_brake / 0.001 + 1 : (t_park + t_brake) / 0.001),
    tau = round(t);
    dir = pi - pi * (tau + 1 - t_brake / 0.001) / (2 * t_park / 0.001);
    [x(tau + 1), y(tau + 1)] = move(x(tau), y(tau), dir, parking_speed, 0.001);
end

% if the parking spot is on the left side, invert the y axis
if (right),
    y = -y;
end

% rotate and add offset
[x, y] = rotate(x, y, direction);
x = x + x0;
y = y + y0;

end
