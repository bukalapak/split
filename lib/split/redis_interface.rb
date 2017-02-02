module Split
  # Simplifies the interface to Redis.
  class RedisInterface
    def initialize
      self.redis = Split.redis
    end

    def persist_list(list_name, list_values)
      max_index = list_length(list_name) - 1
      list_values.each_with_index do |value, index|
        if index > max_index
          add_to_list(list_name, value)
        else
          set_list_index(list_name, index, value)
        end
      end
      make_list_length(list_name, list_values.length)
      list_values
    end

    def add_to_list(list_name, value)
      ::Split::Protor.counter(:split_redis_call_total, 1, class: self.class, method: __method__.to_s, redis: 'rpush')
      redis.rpush(list_name, value)
    end

    def set_list_index(list_name, index, value)
      ::Split::Protor.counter(:split_redis_call_total, 1, class: self.class, method: __method__.to_s, redis: 'lset')
      redis.lset(list_name, index, value)
    end

    def list_length(list_name)
      ::Split::Protor.counter(:split_redis_call_total, 1, class: self.class, method: __method__.to_s, redis: 'llen')
      redis.llen(list_name)
    end

    def remove_last_item_from_list(list_name)
      ::Split::Protor.counter(:split_redis_call_total, 1, class: self.class, method: __method__.to_s, redis: 'rpop')
      redis.rpop(list_name)
    end

    def make_list_length(list_name, new_length)
      while list_length(list_name) > new_length
        remove_last_item_from_list(list_name)
      end
    end

    def add_to_set(set_name, value)
      ::Split::Protor.counter(:split_redis_call_total, 1, class: self.class, method: __method__.to_s, redis: 'sismember')
      return if redis.sismember(set_name, value)
      ::Split::Protor.counter(:split_redis_call_total, 1, class: self.class, method: __method__.to_s, redis: 'sadd')
      redis.sadd(set_name, value)
    end

    private

    attr_accessor :redis
  end
end
